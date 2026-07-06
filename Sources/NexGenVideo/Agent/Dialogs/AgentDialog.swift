import Foundation

/// A generative dialog the agent presents via the `show_dialog` tool (Epic #98 / #96). Placement is
/// the LOCKED architecture: rendered natively as a state of the composer dock — never a modal (it
/// would cover the material the user decides on), never an interactive card in the transcript (it
/// would rot there). Exactly one pending dialog; the user's structured answer flows back as the
/// next user message; the free-text field is the existing input, scoped to this dialog.
/// The user's answer to a presented dialog — selected labels per section, toggle states, and the
/// dialog-scoped free-text direction. Presenter-agnostic: the agent panel turns it into a chat
/// message; a generation panel turns it into a compiled prompt.
struct AgentDialogResult: Sendable, Equatable {
    var selectedLabels: [String: [String]]
    var toggles: [String: Bool]
    var direction: String

    func labels(_ sectionId: String) -> [String] { selectedLabels[sectionId] ?? [] }
    var allLabels: [String] { selectedLabels.values.flatMap { $0 } }
}

struct AgentDialog: Identifiable, Equatable, Sendable {

    struct Choice: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        /// SF Symbol name (Workstream B folds in here — every element carries a semantic icon).
        let symbol: String?
        /// When the choice IS a projected timeline range, its `TimelineRangeCandidate.id` — the card
        /// stays compact and the range is picked on the canvas instead (A3).
        let rangeRef: String?

        init(id: String, label: String, symbol: String? = nil, rangeRef: String? = nil) {
            self.id = id
            self.label = label
            self.symbol = symbol
            self.rangeRef = rangeRef
        }
    }

    /// A candidate that projects onto the canonical timeline (A3): while the dialog is pending it is
    /// drawn as a labeled, clickable highlight; the click selects the matching choice.
    struct TimelineRangeCandidate: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let startFrame: Int
        let endFrame: Int
    }

    /// Where a pending dialog's visual candidates live on the canonical surfaces (A3). Empty means a
    /// plain compact card with no projection.
    struct Projection: Equatable, Sendable {
        var timelineRanges: [TimelineRangeCandidate] = []
        /// A shot id to reveal in the Review gallery (cockpit) while the dialog is pending.
        var reviewShot: String?

        var isEmpty: Bool { timelineRanges.isEmpty && reviewShot == nil }
    }

    struct Section: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case choices(options: [Choice], multiSelect: Bool)
            case toggle(defaultOn: Bool)
        }
        let id: String
        let label: String
        let kind: Kind
    }

    let id: String
    let title: String
    /// SF Symbol shown next to the title.
    let symbol: String
    let intro: String?
    /// e.g. "≈ €0.80 for 2 clips" — surfaced before money is spent.
    let costHint: String?
    let confirmLabel: String
    /// Placeholder for the dialog-scoped free-text input ("Freitext, der nur diesen Dialog voranbringt").
    let textPlaceholder: String?
    let sections: [Section]
    /// Visual candidates projected onto the canvas (timeline ranges / Review shot) instead of the card.
    let projection: Projection

    init(id: String, title: String, symbol: String, intro: String?, costHint: String?,
         confirmLabel: String, textPlaceholder: String?, sections: [Section],
         projection: Projection = Projection()) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.intro = intro
        self.costHint = costHint
        self.confirmLabel = confirmLabel
        self.textPlaceholder = textPlaceholder
        self.sections = sections
        self.projection = projection
    }

    /// Parse the `show_dialog` tool args. Throws with actionable messages so the agent can repair.
    static func parse(_ args: [String: Any]) throws -> AgentDialog {
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            throw ToolError("show_dialog: 'title' is required.")
        }
        var sections: [Section] = []
        for (index, raw) in ((args["sections"] as? [[String: Any]]) ?? []).enumerated() {
            let id = (raw["id"] as? String) ?? "section\(index)"
            let label = (raw["label"] as? String) ?? id
            switch (raw["type"] as? String) ?? "choices" {
            case "toggle":
                sections.append(Section(id: id, label: label,
                                        kind: .toggle(defaultOn: (raw["defaultOn"] as? Bool) ?? false)))
            case "choices":
                let options: [Choice] = ((raw["options"] as? [[String: Any]]) ?? []).enumerated().compactMap { i, opt in
                    guard let optLabel = opt["label"] as? String else { return nil }
                    return Choice(id: (opt["id"] as? String) ?? "option\(i)",
                                  label: optLabel,
                                  symbol: opt["symbol"] as? String,
                                  rangeRef: opt["rangeRef"] as? String)
                }
                guard !options.isEmpty else {
                    throw ToolError("show_dialog: choices section '\(id)' needs a non-empty 'options' array.")
                }
                sections.append(Section(id: id, label: label,
                                        kind: .choices(options: options,
                                                       multiSelect: (raw["multiSelect"] as? Bool) ?? false)))
            case let other:
                throw ToolError("show_dialog: unknown section type '\(other)' (use 'choices' or 'toggle').")
            }
        }
        guard !sections.isEmpty else {
            throw ToolError("show_dialog: at least one section is required — a dialog without structure is just a question; ask in prose instead.")
        }
        let projection = try parseProjection(args["projection"] as? [String: Any])
        return AgentDialog(
            id: UUID().uuidString,
            title: title,
            symbol: (args["symbol"] as? String) ?? "slider.horizontal.3",
            intro: args["intro"] as? String,
            costHint: args["costHint"] as? String,
            confirmLabel: (args["confirmLabel"] as? String) ?? "Continue",
            textPlaceholder: args["textPlaceholder"] as? String,
            sections: sections,
            projection: projection
        )
    }

    private static func parseProjection(_ raw: [String: Any]?) throws -> Projection {
        guard let raw else { return Projection() }
        var ranges: [TimelineRangeCandidate] = []
        for (i, r) in ((raw["timelineRanges"] as? [[String: Any]]) ?? []).enumerated() {
            guard let start = intValue(r["startFrame"]), let end = intValue(r["endFrame"]) else {
                throw ToolError("show_dialog: projection.timelineRanges[\(i)] needs integer 'startFrame' and 'endFrame'.")
            }
            guard end > start else {
                throw ToolError("show_dialog: projection.timelineRanges[\(i)] needs endFrame > startFrame.")
            }
            ranges.append(TimelineRangeCandidate(
                id: (r["id"] as? String) ?? "range\(i)",
                label: (r["label"] as? String) ?? "Range \(i + 1)",
                startFrame: start,
                endFrame: end
            ))
        }
        let reviewShot = (raw["reviewShot"] as? String)?.trimmingCharacters(in: .whitespaces)
        return Projection(timelineRanges: ranges,
                          reviewShot: (reviewShot?.isEmpty == false) ? reviewShot : nil)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}
