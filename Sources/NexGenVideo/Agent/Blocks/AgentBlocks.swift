import Foundation

/// The rich-transcript block protocol (#135): the agent presents status/reports through the
/// `show_blocks` tool, whose input IS this schema — NGV renders the blocks as native UI.
/// The solution space is deliberately tiny (few types, enum-bound values, required fields,
/// unknown keys rejected): a strict parse failure returns a precise tool error the model
/// corrects against. Presentation only — interaction stays with `show_dialog`.
enum AgentBlock: Equatable, Sendable {
    case headline(text: String, symbol: String?)
    case text(body: String)
    case status(badges: [Badge])
    case keyValue(title: String?, rows: [(String, String)])
    case callout(tone: CalloutTone, text: String)

    struct Badge: Equatable, Sendable {
        let label: String
        let value: String
        let symbol: String?
    }

    enum CalloutTone: String, Sendable, CaseIterable {
        case info, warn, success
    }

    static func == (lhs: AgentBlock, rhs: AgentBlock) -> Bool {
        switch (lhs, rhs) {
        case let (.headline(t1, s1), .headline(t2, s2)): return t1 == t2 && s1 == s2
        case let (.text(b1), .text(b2)): return b1 == b2
        case let (.status(b1), .status(b2)): return b1 == b2
        case let (.keyValue(t1, r1), .keyValue(t2, r2)):
            return t1 == t2 && r1.count == r2.count && zip(r1, r2).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.callout(tone1, t1), .callout(tone2, t2)): return tone1 == tone2 && t1 == t2
        default: return false
        }
    }
}

enum AgentBlocks {

    static let maxBlocks = 12
    static let maxBadges = 6
    static let maxRows = 12

    /// Strict parse of the `show_blocks` args. Throws `ToolError` with the exact violation —
    /// the error IS the enforcement loop (the model reads it and re-calls correctly).
    static func parse(_ args: [String: Any]) throws -> [AgentBlock] {
        guard let raw = args["blocks"] as? [[String: Any]], !raw.isEmpty else {
            throw ToolError("show_blocks: 'blocks' must be a non-empty array of block objects.")
        }
        guard raw.count <= maxBlocks else {
            throw ToolError("show_blocks: at most \(maxBlocks) blocks per call (got \(raw.count)).")
        }
        return try raw.enumerated().map { index, dict in
            try parseBlock(dict, at: index)
        }
    }

    private static func parseBlock(_ dict: [String: Any], at index: Int) throws -> AgentBlock {
        guard let type = dict["type"] as? String else {
            throw ToolError("show_blocks: blocks[\(index)] is missing 'type'.")
        }
        switch type {
        case "headline":
            try allowKeys(dict, ["type", "text", "symbol"], index: index)
            return .headline(text: try requiredText(dict, "text", index: index),
                             symbol: dict["symbol"] as? String)
        case "text":
            try allowKeys(dict, ["type", "body"], index: index)
            return .text(body: try requiredText(dict, "body", index: index))
        case "status":
            try allowKeys(dict, ["type", "badges"], index: index)
            guard let rawBadges = dict["badges"] as? [[String: Any]],
                  (1...maxBadges).contains(rawBadges.count) else {
                throw ToolError("show_blocks: blocks[\(index)].badges must hold 1–\(maxBadges) badge objects.")
            }
            let badges = try rawBadges.enumerated().map { badgeIndex, badge in
                try allowKeys(badge, ["label", "value", "symbol"], index: index)
                return AgentBlock.Badge(
                    label: try requiredText(badge, "label", index: index, element: "badges[\(badgeIndex)]"),
                    value: try requiredText(badge, "value", index: index, element: "badges[\(badgeIndex)]"),
                    symbol: badge["symbol"] as? String
                )
            }
            return .status(badges: badges)
        case "keyvalue":
            try allowKeys(dict, ["type", "title", "rows"], index: index)
            guard let rawRows = dict["rows"] as? [[String]],
                  (1...maxRows).contains(rawRows.count),
                  rawRows.allSatisfy({ $0.count == 2 }) else {
                throw ToolError("show_blocks: blocks[\(index)].rows must hold 1–\(maxRows) [label, value] string pairs.")
            }
            return .keyValue(title: dict["title"] as? String,
                             rows: rawRows.map { ($0[0], $0[1]) })
        case "callout":
            try allowKeys(dict, ["type", "tone", "text"], index: index)
            guard let toneRaw = dict["tone"] as? String,
                  let tone = AgentBlock.CalloutTone(rawValue: toneRaw) else {
                let tones = AgentBlock.CalloutTone.allCases.map(\.rawValue).joined(separator: "|")
                throw ToolError("show_blocks: blocks[\(index)].tone must be one of \(tones).")
            }
            return .callout(tone: tone, text: try requiredText(dict, "text", index: index))
        case let other:
            throw ToolError("show_blocks: unknown block type '\(other)' (use headline|text|status|keyvalue|callout).")
        }
    }

    private static func requiredText(
        _ dict: [String: Any], _ key: String, index: Int, element: String? = nil
    ) throws -> String {
        let text = (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            let place = element.map { "blocks[\(index)].\($0)" } ?? "blocks[\(index)]"
            throw ToolError("show_blocks: \(place).\(key) must be a non-empty string.")
        }
        return text
    }

    /// `additionalProperties: false`, enforced by hand — unknown keys are a schema violation.
    private static func allowKeys(_ dict: [String: Any], _ allowed: Set<String>, index: Int) throws {
        let unknown = Set(dict.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ToolError("show_blocks: blocks[\(index)] has unknown keys \(unknown.sorted()) — allowed: \(allowed.sorted()).")
        }
    }
}
