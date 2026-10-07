import AppKit

struct DocumentContentSearch {
    struct Source: Sendable {
        let id: String
        let url: URL
    }

    struct Hit: Sendable, Identifiable {
        let id: String
        let excerpt: String
    }

    struct Result: Sendable {
        var hits: [Hit] = []
        var unavailableIDs: Set<String> = []
    }

    static let maximumBytes = 16 * 1024 * 1024

    static func search(query: String, sources: [Source]) async -> Result {
        let task = Task.detached(priority: .utility) {
            scan(query: query, sources: sources)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func scan(query: String, sources: [Source]) -> Result {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Result() }
        var result = Result()
        for source in sources {
            guard !Task.isCancelled else { return Result() }
            let text: String? = autoreleasepool {
                guard source.url.isFileURL,
                      let handle = try? FileHandle(forReadingFrom: source.url) else { return nil }
                defer { try? handle.close() }
                var data = Data()
                do {
                    while data.count <= maximumBytes {
                        guard !Task.isCancelled else { return nil }
                        let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)) ?? Data()
                        if chunk.isEmpty { break }
                        data.append(chunk)
                    }
                } catch { return nil }
                guard data.count <= maximumBytes else { return nil }
                if source.url.pathExtension.lowercased() == "rtf" {
                    return (try? NSAttributedString(
                        data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                        documentAttributes: nil
                    ))?.string
                }
                return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            }
            guard let text else {
                result.unavailableIDs.insert(source.id)
                continue
            }
            guard let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = text.index(match.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(match.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
            let excerpt = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            result.hits.append(Hit(id: source.id, excerpt: excerpt))
        }
        return result
    }
}
