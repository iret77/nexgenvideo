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
                                  symbol: opt["symbol"] as? String)
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
        return AgentDialog(
            id: UUID().uuidString,
            title: title,
            symbol: (args["symbol"] as? String) ?? "slider.horizontal.3",
            intro: args["intro"] as? String,
            costHint: args["costHint"] as? String,
            confirmLabel: (args["confirmLabel"] as? String) ?? "Continue",
            textPlaceholder: args["textPlaceholder"] as? String,
            sections: sections
        )
    }
}
