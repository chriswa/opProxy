import AppKit
import CoreImage
import OpProxyCore

/// Pairs an iPhone through opProxy iCloud Relay (RelayTransport): shows the QR code, then how
/// it went. The phone's `pair` message is confirmed with Touch ID like any other.
final class PhonePairing {
    private let transport: RelayTransport
    private var window: QRWindow?
    /// Tests: write the QR payload here instead of showing it (OPPROXY_TEST_CLOUD_PAIR).
    var testPayloadFile: URL?

    init(transport: RelayTransport) {
        self.transport = transport
    }

    /// Shows the QR code and waits up to 10 minutes for a phone. Main thread.
    func start() {
        window?.close()
        window = nil
        transport.startPairing { [weak self] update in self?.show(update) }
    }

    private func show(_ update: RelayTransport.PairingUpdate) {
        switch update {
        case .code(let payload):
            if let testPayloadFile {
                try? payload.write(to: testPayloadFile, atomically: true, encoding: .utf8)
                return
            }
            let window = QRWindow(payload: payload) { [weak self] in
                self?.window = nil
                self?.transport.cancelPairing()
            }
            self.window = window
            window.show()
        case .progress(let message):
            window?.finish(message)
        case .finished(let ok, let message):
            guard let window else {
                if !ok, testPayloadFile == nil { Self.alert(message) }
                return
            }
            window.finish(ok ? message : "Pairing didn't finish: \(message)")
            if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { window.close() } }
        }
    }

    /// After updating from a version before 0.3.0, whose pairings had no pairing key: those
    /// phones get nothing until they pair again.
    func askToPairAgain() {
        let alert = NSAlert()
        alert.messageText = "Pair your iPhone again"
        alert.informativeText = "This version of opProxy seals everything it sends your iPhone with a key the two "
            + "make when they pair. Phones paired with an earlier version don't have one, so they won't get requests "
            + "until they pair once more."
        alert.addButton(withTitle: "Pair Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { start() }
    }

    private static func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't pair an iPhone"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
