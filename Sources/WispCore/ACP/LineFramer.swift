import Foundation

/// Splits a byte stream into newline-delimited messages.
///
/// Only `\n` ends a message. JSON strings may legally contain raw U+2028/U+2029, which Foundation's
/// line iterators treat as line breaks, so framing works on bytes instead.
public struct LineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends a chunk and returns every complete, non-empty line it finished.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}
