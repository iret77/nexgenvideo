import Foundation

struct BoundedTextFileRead: Sendable {
    let text: String
    let isTruncated: Bool
}

enum BoundedTextFileReader {
    nonisolated static func readUTF8Prefix(
        from url: URL,
        maximumBytes: Int
    ) throws -> BoundedTextFileRead {
        precondition(maximumBytes > 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: maximumBytes) ?? Data()
        let isTruncated = fileSize > UInt64(maximumBytes)

        if let text = String(data: data, encoding: .utf8) {
            return BoundedTextFileRead(text: text, isTruncated: isTruncated)
        }
        guard isTruncated else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        for removedByteCount in 1...min(3, data.count) {
            if let text = String(
                data: Data(data.dropLast(removedByteCount)),
                encoding: .utf8
            ) {
                return BoundedTextFileRead(text: text, isTruncated: true)
            }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
