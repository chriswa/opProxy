import Foundation

/// The chime a request plays when its dialog opens: two bell notes rising a major sixth,
/// the second held, like a question. Synthesized here rather than shipped as a file.
///
/// Spaceterm's phone plays the same chime for these requests (`approvalRequested` in
/// ~/spaceterm/src/mobile/cues.ts). Keep the two tables in step.
public enum Chime {
    /// (start s, frequency Hz, decay time constant s)
    static let notes: [(start: Double, freq: Double, decay: Double)] = [(0.00, 587.33, 0.16), (0.12, 987.77, 0.42)]
    /// Bell partials of each note: (frequency ratio, amplitude, decay scale).
    static let partials: [(ratio: Double, amp: Double, decay: Double)] = [(1, 1, 1), (2.76, 0.22, 0.45), (5.40, 0.07, 0.25)]
    static let length = 1.1, attack = 0.004, release = 0.06, peak = 0.8
    static let sampleRate = 44_100

    /// Samples in [-peak, peak].
    public static func samples() -> [Double] {
        let n = Int(length * Double(sampleRate))
        var out = [Double](repeating: 0, count: n)
        for note in notes {
            let first = Int(note.start * Double(sampleRate))
            for i in 0..<(n - first) {
                let t = Double(i) / Double(sampleRate)
                let envelope = min(1, t / attack)
                out[first + i] += envelope * partials.reduce(0) { sum, p in
                    sum + p.amp * exp(-t / (note.decay * p.decay)) * sin(2 * .pi * note.freq * p.ratio * t)
                }
            }
        }
        for i in out.indices {
            let left = Double(n - i) / Double(sampleRate)
            if left < release { out[i] *= left / release }
        }
        let loudest = out.map(abs).max() ?? 1
        return out.map { $0 * peak / loudest }
    }

    /// 16-bit mono WAV.
    public static func wav() -> Data {
        let pcm = samples().map { Int16($0 * Double(Int16.max)) }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count * 2))
        pcm.forEach { append($0) }
        return data
    }
}
