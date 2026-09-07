import Foundation

public enum DiagnosticPrivacy {
    public static func scrubJSON(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
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
        return Data(text.utf8)
    }
}
