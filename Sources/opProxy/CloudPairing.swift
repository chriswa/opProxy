import AppKit
import CloudKit
import CoreImage
import OpProxyCore

/// Pairs an iPhone over CloudKit. The Mac shows a QR code with a one-time code; the phone
/// scans it and leaves its zone's share URL in the public database, sealed with that code
/// (CloudFeed.Rendezvous). The Mac joins the zone, and from then on the phone's `pair`
/// message arrives in its inbox and is confirmed with Touch ID like any other.
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
        let code = CloudFeed.Rendezvous.newCode()
        let payload = CloudFeed.Rendezvous.qrPayload(code: code)
        let window = QRWindow(payload: payload) { [weak self] in self?.task?.cancel() }
        self.window = window
        if let testPayloadFile {
            try? payload.write(to: testPayloadFile, atomically: true, encoding: .utf8)
        } else {
            window.show()
        }
        transport.pairingUntil = Date() + 600
        task = Task { [self] in
            let outcome: String
            do {
                outcome = try await rendezvous(code)
            } catch is CancellationError {
                outcome = "cancelled"
            } catch {
                outcome = "failed: \(error)"
            }
            log.write("phone pairing: \(outcome)")
            await MainActor.run { [self] in
                if outcome.hasPrefix("linked") {
                    window.finish("Joined. Confirm the phone's fingerprint on the next prompt.")
                } else if outcome != "cancelled" {
                    window.finish("Pairing didn't finish: \(outcome)")
                }
            }
        }
    }

    private func rendezvous(_ code: Data) async throws -> String {
        let id = CKRecord.ID(recordName: CloudFeed.Rendezvous.recordName(code: code))
        let deadline = Date() + 600
        while Date() < deadline {
            try Task.checkCancellation()
            if let record = try? await container.publicCloudDatabase.record(for: id),
               let sealed = record[CloudFeed.Rendezvous.sealed] as? Data {
                guard let url = CloudFeed.Rendezvous.open(sealed, code: code) else { return "the phone's reply didn't open" }
                try await join(url)
                return "linked"
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return "timed out"
    }

    private func join(_ url: URL) async throws {
        let metadata = try await container.shareMetadata(for: url)
        let zoneID = metadata.share.recordID.zoneID
        let own = metadata.participantRole == .owner
        if !own { _ = try await container.accept(metadata) }
        transport.link(CloudLink(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName, shared: !own, linkedAt: Date()))
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
