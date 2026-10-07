import AppKit
import CloudKit
import CoreImage
import OpProxyCore

/// Pairs an iPhone over CloudKit. The Mac shows a QR code with a one-time code and its own
/// iCloud user; the phone invites that user, and no one else, to its zone's share and leaves
/// the invitation in the public database, sealed with the code (CloudFeed.Rendezvous). The
/// Mac accepts it, and from then on the phone's `pair` message arrives in its inbox and is
/// confirmed with Touch ID like any other.
final class CloudPairing {
    private let transport: CloudTransport
    private let log: Log
    private let container = CKContainer(identifier: CloudFeed.container)
    private var window: QRWindow?
    /// Tests: write the QR payload here instead of showing it (OPPROXY_TEST_CLOUD_PAIR).
    var testPayloadFile: URL?
    private var task: Task<Void, Never>?

    init(transport: CloudTransport, log: Log) {
        self.transport = transport
        self.log = log
    }

    /// Shows the QR code and waits up to 10 minutes for a phone. Main thread.
    func start() {
        task?.cancel()
        transport.pairingUntil = Date() + 600
        task = Task { [self] in
            let outcome: String
            do {
                outcome = try await pair()
            } catch is CancellationError {
                outcome = "cancelled"
            } catch {
                outcome = "failed: \(error)"
            }
            log.write("phone pairing: \(outcome)")
            await MainActor.run { [self] in
                if outcome.hasPrefix("linked") {
                    window?.finish("Joined. Waiting for the phone to ask to be trusted…")
                    awaitPairResult()
                } else if outcome != "cancelled" {
                    window?.finish("Pairing didn't finish: \(outcome)")
                }
            }
        }
    }

    /// The phone's `pair` message comes next; once the Mac has answered it, say so and close.
    private func awaitPairResult() {
        transport.onPairResult = { [weak self] response in
            DispatchQueue.main.async {
                guard let self, let window = self.window else { return }
                self.transport.onPairResult = nil
                if response["ok"] as? Bool == true {
                    window.finish("Paired. Requests will now reach the phone.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { window.close() }
                } else {
                    window.finish("Pairing didn't finish: \(response["error"] as? String ?? "the Mac refused it")")
                }
            }
        }
    }

    private func pair() async throws -> String {
        // The phone shares its zone with this iCloud user alone.
        let me = try await container.userRecordID().recordName
        log.write("phone pairing: showing the code for iCloud user \(me.prefix(10))")
        let code = CloudFeed.Rendezvous.newCode()
        let payload = CloudFeed.Rendezvous.qrPayload(code: code, macUser: me)
        await MainActor.run { [self] in
            let window = QRWindow(payload: payload) { [weak self] in self?.task?.cancel() }
            self.window = window
            if let testPayloadFile {
                try? payload.write(to: testPayloadFile, atomically: true, encoding: .utf8)
            } else {
                window.show()
            }
        }
        let id = CKRecord.ID(recordName: CloudFeed.Rendezvous.recordName(code: code))
        let started = Date()
        let deadline = started + 600
        var lastError = ""
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let record = try await container.publicCloudDatabase.record(for: id)
                guard let sealed = record[CloudFeed.Rendezvous.sealed] as? Data,
                      let invitation = CloudFeed.Rendezvous.open(sealed, code: code) else { return "the phone's reply didn't open" }
                log.write("phone pairing: found the phone's invitation after \(Int(Date().timeIntervalSince(started)))s "
                          + "(written \(record.creationDate.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "at an unknown time"))")
                return try await join(invitation)
            } catch let error as CKError where error.code == .unknownItem {
                // Not written yet.
            } catch {
                // Anything else is worth seeing, once per kind.
                let text = "\(error)"
                if text != lastError { log.write("phone pairing: reading the public database: \(text)") }
                lastError = text
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return "timed out"
    }

    private func join(_ invitation: CloudFeed.Rendezvous.Invitation) async throws -> String {
        switch invitation {
        case .ownZone(let name):
            transport.link(CloudLink(zoneName: name, ownerName: CKCurrentUserDefaultName, shared: false, linkedAt: Date()))
            return "linked: own zone"
        case .share(let url):
            let fetching = Date()
            let metadata = try await container.shareMetadata(for: url)
            log.write("phone pairing: share metadata in \(String(format: "%.1f", Date().timeIntervalSince(fetching)))s: "
                      + "public \(metadata.share.publicPermission.rawValue), my role \(metadata.participantRole.rawValue), "
                      + "status \(metadata.participantStatus.rawValue), participants "
                      + metadata.share.participants.map { "\($0.role.rawValue)/\($0.acceptanceStatus.rawValue)/\($0.userIdentity.userRecordID?.recordName.prefix(10) ?? "?")" }.joined(separator: ", "))
            // Joining through an open link would mean anyone holding it could too.
            guard metadata.share.publicPermission == .none else { return "refused: the phone's share is open to anyone with its link" }
            let accepting = Date()
            _ = try await container.accept(metadata)
            log.write("phone pairing: accepted in \(String(format: "%.1f", Date().timeIntervalSince(accepting)))s")
            let zoneID = metadata.share.recordID.zoneID
            transport.link(CloudLink(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName, shared: true, linkedAt: Date()))
            return "linked: invited to a private share with \(metadata.share.participants.count) participants"
        }
    }
}

/// A small window with the pairing QR code.
private final class QRWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let onClose: () -> Void

    init(payload: String, onClose: @escaping () -> Void) {
        self.onClose = onClose
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420), styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Pair an iPhone"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let image = NSImageView(image: Self.qr(payload, size: 260))
        caption.stringValue = "Open opProxy on your iPhone and scan this code. It works once, for 10 minutes."
        caption.alignment = .center
        let stack = NSStackView(views: [image, caption])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        panel.contentView = stack
    }

    func show() {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func finish(_ message: String) {
        caption.stringValue = message
    }

    func close() { panel.close() }

    func windowWillClose(_ notification: Notification) { onClose() }

    private static func qr(_ text: String, size: CGFloat) -> NSImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = filter.outputImage!
        let scaled = output.transformed(by: CGAffineTransform(scaleX: size / output.extent.width, y: size / output.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
