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
    /// The dialog's single free-text field (`AgentDialog.textField`), when it declares one.
    var direction: String
    /// Per-section "Other…" free text, for choice sections that set `allowsCustom` — keyed by section id.
    var customValues: [String: String] = [:]
    /// Files the user dropped or picked in a `fileIntake` dialog. The host imports each as a media
    /// asset and hands the agent an @mention — the user never types, and no path travels as prose.
    var fileURLs: [URL] = []

    func labels(_ sectionId: String) -> [String] { selectedLabels[sectionId] ?? [] }
    var allLabels: [String] { selectedLabels.values.flatMap { $0 } }
    /// A section's picked labels plus its "Other…" text (if any), for message composition.
    func values(_ sectionId: String) -> [String] {
        var out = labels(sectionId)
        if let custom = customValues[sectionId]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            out.append(custom)
        }
        return out
    }
}

struct AgentDialog: Identifiable, Equatable, Sendable {

    /// What submitting the dialog does (audit #3). A single dialog type, two purposes, routed by ONE
    /// handler so no surface re-implements dialog submission:
    /// - `.chatClarification` composes a structured chat message (the agent's `show_dialog` default).
    /// - `.generationIntent` builds a generation and runs it through `GenerationController` — the
    ///   music-shaping dialog is this purpose. Presenter-agnostic: the panel that owns a generation
    ///   dialog supplies the builder; the agent panel only ever composes a message.
    enum Purpose: Equatable, Sendable {
        case chatClarification
        case generationIntent
    }

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
        /// For a choices section: also render a system "Other…" free-text so the user isn't boxed into
        /// the preset options. The typed value comes back in `AgentDialogResult.customValues[id]`.
        let allowsCustom: Bool

        init(id: String, label: String, kind: Kind, allowsCustom: Bool = false) {
            self.id = id
            self.label = label
            self.kind = kind
            self.allowsCustom = allowsCustom
        }
    }

    /// The dialog's single free-text field. Explicit (the agent declares it) rather than an always-on
    /// input, and sized to its job — `multiline` for lyrics/notes, single-line for a short direction.
    struct DialogTextField: Equatable, Sendable {
        let placeholder: String
        let multiline: Bool
    }

    /// Turns the dialog into a file intake: the card replaces its free-text field with a drop zone +
    /// a native file picker, so the user drops or chooses the file(s) and never types a path. Picked
    /// files come back in `AgentDialogResult.fileURLs`; the host imports each as a media asset and
    /// references it to the agent as an @mention (e.g. `attach_song media:<id>`).
    struct FileIntake: Equatable, Sendable {
        /// Accepted tokens — a kind ("audio", "video"/"movie", "image", "text") or a bare extension
        /// ("mp3", "txt"). Empty ⇒ any file.
        let accept: [String]
        /// Short line shown in the empty drop well.
        let prompt: String?
        let allowsMultiple: Bool
        /// Where the chosen file goes. Default (nil) ⇒ the media library, referenced back as an
        /// @mention (the song path). `"lyrics"`/`"script"` ⇒ host writes a text sidecar. `"character"`/
        /// `"location"` ⇒ host copies the images into `import/<characters|locations>/<slug>/` (the bible
        /// anchor convention), using `namePrompt`'s value as the identity name.
        let attachAs: String?
        /// When set, the well also shows a required identity-name field (e.g. "Character name"). Used by
        /// the `character`/`location` intakes so the host can name the destination folder. The name
        /// arrives in `AgentDialogResult.direction`.
        let namePrompt: String?
        /// Whether a file (or, with a textField, text) is REQUIRED to confirm. Optional intakes (lyrics,
        /// script) can be confirmed with nothing — that's an explicit "skip", reported to the agent so
        /// it moves on instead of the user being forced to dismiss.
        let required: Bool
    }

    let id: String
    let title: String
    /// SF Symbol shown next to the title.
    let symbol: String
    let intro: String?
    /// e.g. "≈ €0.80 for 2 clips" — surfaced before money is spent.
    let costHint: String?
    let confirmLabel: String
    /// The dialog's single free-text field, when it declares one. Explicit, not always-on.
    let textField: DialogTextField?
    let sections: [Section]
    /// When set, the card shows a drop zone + native file picker.
    let fileIntake: FileIntake?
    /// Visual candidates projected onto the canvas (timeline ranges / Review shot) instead of the card.
    let projection: Projection
    /// What submitting does — defaults to chat clarification (the agent's `show_dialog` path).
    let purpose: Purpose

    init(id: String, title: String, symbol: String, intro: String?, costHint: String?,
         confirmLabel: String, textField: DialogTextField?, sections: [Section],
         fileIntake: FileIntake? = nil,
         projection: Projection = Projection(), purpose: Purpose = .chatClarification) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.intro = intro
        self.costHint = costHint
        self.confirmLabel = confirmLabel
        self.textField = textField
        self.sections = sections
        self.fileIntake = fileIntake
        self.projection = projection
        self.purpose = purpose
    }

    /// Parse the `show_dialog` tool args. Throws with actionable messages so the agent can repair.
    static func parse(_ args: [String: Any]) throws -> AgentDialog {
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            throw ToolError("show_dialog: 'title' is required.")
        }
        let rawSections = (args["sections"] as? [[String: Any]]) ?? []
        // GUARDRAIL: a dialog stays a focused decision, not a wall of controls. Overloaded dialogs must
        // be split into sub-steps by the agent — the schema won't render more than this.
        guard rawSections.count <= Self.maxSections else {
            throw ToolError("show_dialog: at most \(Self.maxSections) sections — split a bigger decision into separate, focused dialogs.")
        }
        var sections: [Section] = []
        for (index, raw) in rawSections.enumerated() {
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
                // GUARDRAIL: enough to be a choice, few enough to scan. Set allowsCustom for open sets.
                guard options.count >= 2, options.count <= Self.maxOptionsPerSection else {
                    throw ToolError("show_dialog: choices section '\(id)' needs 2…\(Self.maxOptionsPerSection) options (set allowsCustom for an open 'Other…' field).")
                }
                sections.append(Section(id: id, label: label,
                                        kind: .choices(options: options,
                                                       multiSelect: (raw["multiSelect"] as? Bool) ?? false),
                                        allowsCustom: (raw["allowsCustom"] as? Bool) ?? false))
            case let other:
                throw ToolError("show_dialog: unknown section type '\(other)' (use 'choices' or 'toggle').")
            }
        }
        let textField = parseTextField(args)
        let fileIntake = parseFileIntake(args["fileIntake"] as? [String: Any])
        guard !sections.isEmpty || fileIntake != nil || textField != nil else {
            throw ToolError("show_dialog: give it structure — at least one section, a textField, or a fileIntake; a bare question belongs in prose.")
        }
        let projection = try parseProjection(args["projection"] as? [String: Any])
        return AgentDialog(
            id: UUID().uuidString,
            title: title,
            symbol: (args["symbol"] as? String) ?? "slider.horizontal.3",
            intro: args["intro"] as? String,
            costHint: args["costHint"] as? String,
            confirmLabel: (args["confirmLabel"] as? String) ?? "Continue",
            textField: textField,
            sections: sections,
            fileIntake: fileIntake,
            projection: projection
        )
    }

    /// GUARDRAILS for agent-generated dialogs — the vocabulary is fixed and bounded so a card can never
    /// render as an overloaded or malformed wall of controls (schema-enforced, not prompt discipline).
    static let maxSections = 3
    static let maxOptionsPerSection = 8

    /// The one free-text field, if declared. New `textField: {placeholder, multiline}` object, or the
    /// legacy single-line `textPlaceholder` string.
    private static func parseTextField(_ args: [String: Any]) -> DialogTextField? {
        if let raw = args["textField"] as? [String: Any] {
            let placeholder = (raw["placeholder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return DialogTextField(placeholder: placeholder.isEmpty ? "Add a note (optional)…" : placeholder,
                                   multiline: (raw["multiline"] as? Bool) ?? false)
        }
        if let legacy = (args["textPlaceholder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty {
            return DialogTextField(placeholder: legacy, multiline: false)
        }
        return nil
    }

    private static func parseFileIntake(_ raw: [String: Any]?) -> FileIntake? {
        guard let raw else { return nil }
        let accept = ((raw["accept"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let prompt = (raw["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachAs = ((raw["attachAs"] as? String)?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        let namePrompt = (raw["namePrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Optional intakes (lyrics/script text sidecars, style refs) default to skippable — the user
        // can confirm-to-skip. The agent can force required:true; other intakes (the song) require input.
        let defaultRequired = !(attachAs == "lyrics" || attachAs == "script" || attachAs == "style")
        return FileIntake(
            accept: accept,
            prompt: (prompt?.isEmpty == false) ? prompt : nil,
            allowsMultiple: (raw["multiple"] as? Bool) ?? false,
            attachAs: attachAs,
            namePrompt: (namePrompt?.isEmpty == false) ? namePrompt : nil,
            required: (raw["required"] as? Bool) ?? defaultRequired
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
