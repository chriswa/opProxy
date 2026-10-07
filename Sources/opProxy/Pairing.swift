import AppKit
import LocalAuthentication
import OpProxyCore

/// Confirms a phone's pairing on the Mac itself: a dialog naming the phone with its key's
/// fingerprint, then Touch ID, whose context signs the paired-device entry with the approval
/// key. Without both, a `pair` message from an agent pairs nothing.
enum Pairing {
    /// `autoPair` (the `OPPROXY_TEST_AUTO_PAIR` knob, debug builds only) skips the dialog.
    static func confirmer(devices: PairedDeviceStore, signer: ApprovalSigner?, autoPair: Bool) -> ApprovalFeed.ConfirmPairing {
        return { name, publicKey, done in
            guard let signer else { return done("This opProxy build has no approval key; run install.sh.") }
            func pair(_ context: LAContext?) {
                do {
                    try devices.pair(publicKey: publicKey, name: name) { try signer.sign($0, context: context) }
                    done(nil)
                } catch {
                    done("Could not sign the pairing on the Mac: \(error)")
                }
            }
            if autoPair { return pair(nil) }
            let fingerprint = DeviceKey.fingerprint(keyId: DeviceKey.keyId(rawPublicKey: publicKey))
            DispatchQueue.main.async {
                PairingPrompt(name: name, fingerprint: fingerprint).show { confirmed in
                    guard confirmed else { return done("Pairing was cancelled on the Mac.") }
                    let context = LAContext()
                    context.evaluateAccessControl(EnclaveSigner.accessControl(), operation: .useKeySign,
                                                  localizedReason: "pair “\(name)” to approve 1Password requests") { ok, _ in
                        if ok { pair(context) } else { done("Touch ID didn't confirm the pairing.") }
                        context.invalidate()
                    }
                }
            }
        }
    }
}

/// An alert that doesn't run modally, so approval dialogs stay usable while it's up.
private final class PairingPrompt: NSObject {
    private let alert = NSAlert()
    private var completion: ((Bool) -> Void)?
    private var retainSelf: PairingPrompt?

    init(name: String, fingerprint: String) {
        super.init()
        alert.messageText = "Pair “\(name)” with opProxy?"
        alert.informativeText = "This phone wants to approve 1Password requests from opProxy, including lasting approvals. "
            + "Only pair it if you just asked to, in the Spaceterm app.\n\nCheck your phone shows the same fingerprint:"
        alert.icon = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Phone")
        let print = NSTextField(labelWithString: fingerprint)
        print.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        print.textColor = Caution.accent
        print.isSelectable = true
        print.sizeToFit()
        alert.accessoryView = print
        alert.addButton(withTitle: "Pair…")
        alert.addButton(withTitle: "Cancel")
        for (i, button) in alert.buttons.enumerated() {
            button.tag = i
            button.target = self
            button.action = #selector(clicked(_:))
        }
    }

    func show(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
        retainSelf = self
        alert.layout()
        let window = alert.window
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = .floating
        window.center()
        window.presentForAnswer()
    }

    @objc private func clicked(_ sender: NSButton) {
        alert.window.orderOut(nil)
        completion?(sender.tag == 0)
        completion = nil
        retainSelf = nil
    }
}
