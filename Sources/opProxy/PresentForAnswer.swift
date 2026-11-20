import AppKit

extension NSWindow {
    /// How opProxy puts a window that needs an answer in front of you: it takes focus.
    func presentForAnswer() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}
