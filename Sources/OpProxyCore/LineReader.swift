import Darwin
import Foundation

/// Buffered newline-delimited reads from a file descriptor (socket or pipe).
public final class LineReader {
    private let fd: Int32
    private let limit: Int
    private var buffer = Data()
    private var eof = false

    public init(fd: Int32, limit: Int = 256 << 20) {
        self.fd = fd
        self.limit = limit
    }

    /// The next line without its `\n`; a final unterminated line is returned at EOF.
    public func next() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            if eof || buffer.count > limit {
                defer { buffer.removeAll() }
                return buffer.isEmpty || buffer.count > limit ? nil : buffer
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { eof = true } else { buffer.append(chunk, count: n) }
        }
    }
}
