import Foundation

public enum DiagnosticPrivacy {
    public static func scrubJSON(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let output = try? JSONSerialization.data(withJSONObject: scrub(object, depth: 0), options: [.sortedKeys]) else {
            return Data()
        }
        return output
    }

    private static func scrub(_ object: Any, depth: Int) -> Any {
        guard depth < 128 else { return "[redacted-depth-limit]" }
        if let dictionary = object as? [String: Any] {
            return dictionary.mapValues { scrub($0, depth: depth + 1) }
                .reduce(into: [String: Any]()) { result, entry in
                    let forbidden = ["api_key", "apikey", "authorization", "access_token", "refresh_token", "password", "secret"]
                    result[entry.key] = forbidden.contains(entry.key.lowercased()) ? "[redacted]" : entry.value
                }
        }
        if let array = object as? [Any] { return array.map { scrub($0, depth: depth + 1) } }
        guard var text = object as? String else { return object }
        if depth < 16, (text.hasPrefix("{") || text.hasPrefix("[")),
           let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
           let bytes = try? JSONSerialization.data(withJSONObject: scrub(nested, depth: depth + 1), options: [.sortedKeys]) {
            text = String(decoding: bytes, as: UTF8.self)
        }
        let patterns = [
            #"(?i)(?:sk-ant-|sk-proj-|sk-|ghp_|github_pat_)[A-Za-z0-9_\-]{12,}"#,
            #"(?i)Bearer\s+[A-Za-z0-9._\-+/=]+"#,
            #"(?i)(?:https?:)(?:\\?/){2}[^\s"<>]*\?[^\s"<>]*"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            text = expression.stringByReplacingMatches(in: text,
                range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted]")
        }
        return text
    }
}
