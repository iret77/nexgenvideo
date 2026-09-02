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

    static let currentVersion = "1"
    static let maxBlocks = 6
    static let maxBadges = 4
    static let maxRows = 8
    static let maxHeadlineLength = 120
    static let maxBodyLength = 1_600
    static let maxLabelLength = 80
    static let maxValueLength = 600
    private static let legacyMaxBlocks = 12
    private static let legacyMaxBadges = 6
    private static let legacyMaxRows = 12

    /// Strict parse of the `show_blocks` args. Throws `ToolError` with the exact violation —
    /// the error IS the enforcement loop (the model reads it and re-calls correctly).
    static func parse(_ args: [String: Any]) throws -> [AgentBlock] {
        let allowedRootKeys: Set<String> = ["version", "blocks"]
        let unknownRootKeys = Set(args.keys).subtracting(allowedRootKeys)
        guard unknownRootKeys.isEmpty else {
            throw ToolError(
                "show_blocks: unknown root keys \(unknownRootKeys.sorted()) — allowed: \(allowedRootKeys.sorted())."
            )
        }
        guard args["version"] as? String == currentVersion else {
            throw ToolError("show_blocks: 'version' must be '\(currentVersion)'.")
        }
        guard let raw = args["blocks"] as? [[String: Any]], !raw.isEmpty else {
            throw ToolError("show_blocks: 'blocks' must be a non-empty array of block objects.")
        }
        guard raw.count <= maxBlocks else {
            throw ToolError("show_blocks: at most \(maxBlocks) blocks per call (got \(raw.count)).")
        }
        let parsed = try raw.enumerated().map { index, dict in
            try parseBlock(dict, at: index)
        }
        try validateGrammar(parsed)
        return parsed
    }

    static func parseForRendering(_ args: [String: Any]) -> [AgentBlock]? {
        if args["version"] != nil { return try? parse(args) }
        return try? parseLegacy(args)
    }

    private static func parseLegacy(_ args: [String: Any]) throws -> [AgentBlock] {
        guard let raw = args["blocks"] as? [[String: Any]], !raw.isEmpty,
              raw.count <= legacyMaxBlocks else {
            throw ToolError("show_blocks: unsupported legacy payload.")
        }
        return try raw.enumerated().map { index, block in
            try parseLegacyBlock(block, at: index)
        }
    }

    private static func parseLegacyBlock(
        _ dict: [String: Any],
        at index: Int
    ) throws -> AgentBlock {
        guard let type = dict["type"] as? String else {
            throw ToolError("show_blocks: blocks[\(index)] is missing 'type'.")
        }
        switch type {
        case "headline":
            try allowKeys(dict, ["type", "text", "symbol"], index: index)
            return .headline(
                text: try requiredLegacyText(
                    dict,
                    "text",
                    index: index,
                    maxLength: maxHeadlineLength
                ),
                symbol: dict["symbol"] as? String
            )
        case "text":
            try allowKeys(dict, ["type", "body"], index: index)
            return .text(body: try requiredLegacyText(
                dict,
                "body",
                index: index,
                maxLength: maxBodyLength
            ))
        case "status":
            try allowKeys(dict, ["type", "badges"], index: index)
            guard let badges = dict["badges"] as? [[String: Any]],
                  (1...legacyMaxBadges).contains(badges.count) else {
                throw ToolError("show_blocks: unsupported legacy status payload.")
            }
            return .status(badges: try badges.enumerated().map { badgeIndex, badge in
                try allowKeys(badge, ["label", "value", "symbol"], index: index)
                return AgentBlock.Badge(
                    label: try requiredLegacyText(
                        badge,
                        "label",
                        index: index,
                        element: "badges[\(badgeIndex)]",
                        maxLength: maxLabelLength
                    ),
                    value: try requiredLegacyText(
                        badge,
                        "value",
                        index: index,
                        element: "badges[\(badgeIndex)]",
                        maxLength: maxValueLength
                    ),
                    symbol: badge["symbol"] as? String
                )
            })
        case "keyvalue":
            try allowKeys(dict, ["type", "title", "rows"], index: index)
            guard let rows = dict["rows"] as? [[String]],
                  (1...legacyMaxRows).contains(rows.count),
                  rows.allSatisfy({ $0.count == 2 }) else {
                throw ToolError("show_blocks: unsupported legacy key-value payload.")
            }
            let boundedRows = try rows.enumerated().map { rowIndex, row in
                let label = try boundedText(
                    row[0],
                    path: "blocks[\(index)].rows[\(rowIndex)][0]",
                    maxLength: maxLabelLength
                )
                let value = try boundedText(
                    row[1],
                    path: "blocks[\(index)].rows[\(rowIndex)][1]",
                    maxLength: maxValueLength
                )
                return (label, value)
            }
            let title = try (dict["title"] as? String).map {
                try boundedText(
                    $0,
                    path: "blocks[\(index)].title",
                    maxLength: maxHeadlineLength
                )
            }
            return .keyValue(title: title, rows: boundedRows)
        case "callout":
            try allowKeys(dict, ["type", "tone", "text"], index: index)
            guard let rawTone = dict["tone"] as? String,
                  let tone = AgentBlock.CalloutTone(rawValue: rawTone) else {
                throw ToolError("show_blocks: unsupported legacy callout payload.")
            }
            return .callout(
                tone: tone,
                text: try requiredLegacyText(
                    dict,
                    "text",
                    index: index,
                    maxLength: maxValueLength
                )
            )
        default:
            throw ToolError("show_blocks: unsupported legacy block type.")
        }
    }

    private static func requiredLegacyText(
        _ dict: [String: Any],
        _ key: String,
        index: Int,
        element: String? = nil,
        maxLength: Int
    ) throws -> String {
        let place = element.map { "blocks[\(index)].\($0)" } ?? "blocks[\(index)]"
        return try boundedText(
            dict[key] as? String ?? "",
            path: "\(place).\(key)",
            maxLength: maxLength
        )
    }

    private static func parseBlock(_ dict: [String: Any], at index: Int) throws -> AgentBlock {
        guard let type = dict["type"] as? String else {
            throw ToolError("show_blocks: blocks[\(index)] is missing 'type'.")
        }
        switch type {
        case "headline":
            try allowKeys(dict, ["type", "text"], index: index)
            return .headline(text: try requiredText(
                dict,
                "text",
                index: index,
                maxLength: maxHeadlineLength
            ),
                             symbol: nil)
        case "text":
            try allowKeys(dict, ["type", "body"], index: index)
            return .text(body: try requiredText(
                dict,
                "body",
                index: index,
                maxLength: maxBodyLength
            ))
        case "status":
            try allowKeys(dict, ["type", "badges"], index: index)
            guard let rawBadges = dict["badges"] as? [[String: Any]],
                  (1...maxBadges).contains(rawBadges.count) else {
                throw ToolError("show_blocks: blocks[\(index)].badges must hold 1–\(maxBadges) badge objects.")
            }
            let badges = try rawBadges.enumerated().map { badgeIndex, badge in
                try allowKeys(badge, ["label", "value"], index: index)
                return AgentBlock.Badge(
                    label: try requiredText(
                        badge,
                        "label",
                        index: index,
                        element: "badges[\(badgeIndex)]",
                        maxLength: maxLabelLength
                    ),
                    value: try requiredText(
                        badge,
                        "value",
                        index: index,
                        element: "badges[\(badgeIndex)]",
                        maxLength: maxValueLength
                    ),
                    symbol: nil
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
            let rows = try rawRows.enumerated().map { rowIndex, row in
                let label = try boundedText(
                    row[0],
                    path: "blocks[\(index)].rows[\(rowIndex)][0]",
                    maxLength: maxLabelLength
                )
                let value = try boundedText(
                    row[1],
                    path: "blocks[\(index)].rows[\(rowIndex)][1]",
                    maxLength: maxValueLength
                )
                return (label, value)
            }
            let title = try (dict["title"] as? String).map {
                try boundedText(
                    $0,
                    path: "blocks[\(index)].title",
                    maxLength: maxHeadlineLength
                )
            }
            return .keyValue(title: title, rows: rows)
        case "callout":
            try allowKeys(dict, ["type", "tone", "text"], index: index)
            guard let toneRaw = dict["tone"] as? String,
                  let tone = AgentBlock.CalloutTone(rawValue: toneRaw) else {
                let tones = AgentBlock.CalloutTone.allCases.map(\.rawValue).joined(separator: "|")
                throw ToolError("show_blocks: blocks[\(index)].tone must be one of \(tones).")
            }
            return .callout(tone: tone, text: try requiredText(
                dict,
                "text",
                index: index,
                maxLength: maxValueLength
            ))
        case let other:
            throw ToolError("show_blocks: unknown block type '\(other)' (use headline|text|status|keyvalue|callout).")
        }
    }

    private static func requiredText(
        _ dict: [String: Any],
        _ key: String,
        index: Int,
        element: String? = nil,
        maxLength: Int
    ) throws -> String {
        let place = element.map { "blocks[\(index)].\($0)" } ?? "blocks[\(index)]"
        return try boundedText(
            dict[key] as? String ?? "",
            path: "\(place).\(key)",
            maxLength: maxLength
        )
    }

    private static func boundedText(
        _ value: String,
        path: String,
        maxLength: Int
    ) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ToolError("show_blocks: \(path) must be a non-empty string.")
        }
        guard text.count <= maxLength else {
            throw ToolError("show_blocks: \(path) exceeds \(maxLength) characters.")
        }
        return text
    }

    private static func validateGrammar(_ blocks: [AgentBlock]) throws {
        let headlineIndices = blocks.indices.filter {
            if case .headline = blocks[$0] { return true }
            return false
        }
        guard headlineIndices.count <= 1, headlineIndices.first.map({ $0 == 0 }) ?? true else {
            throw ToolError("show_blocks: headline is optional, unique, and must be the first block.")
        }
        let statusCount = blocks.filter {
            if case .status = $0 { return true }
            return false
        }.count
        guard statusCount <= 1 else {
            throw ToolError("show_blocks: at most one status block is allowed.")
        }
        let textCount = blocks.filter {
            if case .text = $0 { return true }
            return false
        }.count
        guard textCount <= 1 else {
            throw ToolError("show_blocks: at most one body text block is allowed.")
        }
        let keyValueCount = blocks.filter {
            if case .keyValue = $0 { return true }
            return false
        }.count
        guard keyValueCount <= 2 else {
            throw ToolError("show_blocks: at most two key-value blocks are allowed.")
        }
        let calloutIndices = blocks.indices.filter {
            if case .callout = blocks[$0] { return true }
            return false
        }
        guard calloutIndices.count <= 1,
              calloutIndices.first.map({ $0 == blocks.count - 1 }) ?? true else {
            throw ToolError("show_blocks: callout is optional, unique, and must be the last block.")
        }
        let ranks = blocks.map { block -> Int in
            switch block {
            case .headline: 0
            case .text: 1
            case .status: 2
            case .keyValue: 3
            case .callout: 4
            }
        }
        guard zip(ranks, ranks.dropFirst()).allSatisfy({ pair in
            pair.0 <= pair.1
        }) else {
            throw ToolError(
                "show_blocks: blocks must use fixed slot order headline, text, status, key-value, callout."
            )
        }
    }

    /// `additionalProperties: false`, enforced by hand — unknown keys are a schema violation.
    private static func allowKeys(_ dict: [String: Any], _ allowed: Set<String>, index: Int) throws {
        let unknown = Set(dict.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ToolError("show_blocks: blocks[\(index)] has unknown keys \(unknown.sorted()) — allowed: \(allowed.sorted()).")
        }
    }
}
