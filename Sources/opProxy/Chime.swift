import AppKit
import OpProxyCore

extension Chime {
    private static let sound = NSSound(data: wav())

    /// Fire-and-forget; silent if there's no audio device.
    static func play() {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }
}
