import Foundation
import NexGenEngine
import UniformTypeIdentifiers

/// The user's structured answer to a presented dialog.
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

/// User-operated controls rendered separately from typed prose.
struct AgentChoiceRecord: Codable, Equatable, Sendable {
    struct Selection: Codable, Equatable, Sendable {
        let label: String
        let values: [String]
    }

    let selections: [Selection]
    let attachmentNames: [String]
    let confirmed: Bool

    var summary: String {
        var parts = selections.map { "\($0.label): \($0.values.joined(separator: ", "))" }
        if !attachmentNames.isEmpty {
            parts.append("\(attachmentNames.count == 1 ? "File" : "Files"): \(attachmentNames.joined(separator: ", "))")
        }
        if parts.isEmpty, confirmed { return "Confirmed" }
        return parts.joined(separator: " · ")
    }
}

struct AgentWorkflowRecord: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        case attached
        case provided
        case skipped
        case completed
    }

    let title: String
    let symbol: String
    let phase: String?
    let detail: String?
    let attachmentNames: [String]
    let outcome: Outcome

    init(
        title: String,
        symbol: String,
        phase: String? = nil,
        detail: String?,
        attachmentNames: [String],
        outcome: Outcome
    ) {
        self.title = title
        self.symbol = symbol
        self.phase = phase
        self.detail = detail
        self.attachmentNames = attachmentNames
        self.outcome = outcome
    }
}

struct AgentUserPresentation: Codable, Equatable, Sendable {
    let choiceRecord: AgentChoiceRecord?
    let typedText: String?
    let notice: String?
    let workflowRecord: AgentWorkflowRecord?

    init(
        choiceRecord: AgentChoiceRecord?,
        typedText: String?,
        notice: String? = nil,
        workflowRecord: AgentWorkflowRecord? = nil
    ) {
        self.choiceRecord = choiceRecord
        self.typedText = typedText
        self.notice = notice
        self.workflowRecord = workflowRecord
    }
}

struct AgentControlTurn: Equatable, Sendable {
    let command: String
    let presentation: AgentUserPresentation

    init(
        command: String,
        selections: [AgentChoiceRecord.Selection] = [],
        typedText: String? = nil
    ) {
        self.command = command
        let record = selections.isEmpty ? nil : AgentChoiceRecord(
            selections: selections,
            attachmentNames: [],
            confirmed: false
        )
        self.presentation = AgentUserPresentation(
            choiceRecord: record,
            typedText: typedText?.isEmpty == false ? typedText : nil
        )
    }
}

struct AgentDialog: Identifiable, Equatable, Sendable {

    /// Routes every dialog through the single submission handler.
    enum Purpose: Equatable, Sendable {
        case chatClarification
        case generationIntent
        case workflowIntake
    }

    enum WorkflowDecision: String, Equatable, Sendable {
        case analysisTempo = "analysis_tempo"
        case analysisInterpretationReview = "analysis_interpretation_review"
        case analysisTrackReplacement = "analysis_track_replacement"
    }

    struct Choice: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        /// Compact transcript value without explanatory copy.
        let shortLabel: String
        /// SF Symbol name (Workstream B folds in here — every element carries a semantic icon).
        let symbol: String?
        /// When the choice IS a projected timeline range, its `TimelineRangeCandidate.id` — the card
        /// stays compact and the range is picked on the canvas instead (A3).
        let rangeRef: String?

        init(
            id: String,
            label: String,
            shortLabel: String? = nil,
            symbol: String? = nil,
            rangeRef: String? = nil
        ) {
            self.id = id
            self.label = label
            self.shortLabel = Self.compactLabel(shortLabel, fallback: label)
            self.symbol = symbol
            self.rangeRef = rangeRef
        }

        private static func compactLabel(_ explicit: String?, fallback: String) -> String {
            let value = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let compact = value.isEmpty
                ? AgentDialog.compactTranscriptLabel(fallback)
                : value
            return AgentDialog.limitedChoiceDisplayLabel(compact)
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
        /// Compact transcript key, e.g. "Shots" for "How shots are sourced".
        let shortLabel: String
        let kind: Kind
        /// For a choices section: also render a system "Other…" free-text so the user isn't boxed into
        /// the preset options. The typed value comes back in `AgentDialogResult.customValues[id]`.
        let allowsCustom: Bool

        init(
            id: String,
            label: String,
            shortLabel: String? = nil,
            kind: Kind,
            allowsCustom: Bool = false
        ) {
            self.id = id
            self.label = label
            let value = shortLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.shortLabel = value.isEmpty ? AgentDialog.compactTranscriptLabel(label) : value
            self.kind = kind
            self.allowsCustom = allowsCustom
        }

        func transcriptValue(for selectedLabel: String) -> String {
            if case .choices(let options, _) = kind,
               let choice = options.first(where: { $0.label == selectedLabel }) {
                return choice.shortLabel
            }
            return AgentDialog.compactTranscriptLabel(selectedLabel)
        }
    }

    /// The dialog's single free-text field. Explicit rather than always-on and sized to its job.
    struct DialogTextField: Equatable, Sendable {
        let placeholder: String
        let multiline: Bool
    }

    /// File intake shown as a drop zone and native picker.
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
        /// Whether the workflow step itself may be completed without content.
        let required: Bool
        /// Finishes an optional intake without submitting the current draft.
        let completionLabel: String?
        /// Pack-owned label for adding another file to the same item.
        let addFileLabel: String?

        init(
            accept: [String],
            prompt: String?,
            allowsMultiple: Bool,
            attachAs: String?,
            namePrompt: String?,
            required: Bool,
            completionLabel: String? = nil,
            addFileLabel: String? = nil
        ) {
            self.accept = accept
            self.prompt = prompt
            self.allowsMultiple = allowsMultiple
            self.attachAs = attachAs
            self.namePrompt = namePrompt
            self.required = required
            self.completionLabel = completionLabel
            self.addFileLabel = addFileLabel
        }
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
    /// Bounded reason for an agent-authored decision while a locked workflow phase is active.
    let workflowDecision: WorkflowDecision?

    init(id: String, title: String, symbol: String, intro: String?, costHint: String?,
         confirmLabel: String, textField: DialogTextField?, sections: [Section],
         fileIntake: FileIntake? = nil,
         projection: Projection = Projection(), purpose: Purpose = .chatClarification,
         workflowDecision: WorkflowDecision? = nil) {
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
        self.workflowDecision = workflowDecision
    }

    /// Derives a compact label when the dialog omits `shortLabel`.
    static func compactTranscriptLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [" — ", " – ", "\n"]
        let head = separators.compactMap { trimmed.range(of: $0)?.lowerBound }
            .min()
            .map { String(trimmed[..<$0]) } ?? trimmed
        let words = head.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first?.lowercased() == "how",
           let auxiliary = words.indices.dropFirst().first(where: {
               ["is", "are", "was", "were", "will", "should", "can"].contains(words[$0].lowercased())
           }), auxiliary > 1 {
            let subject = words[1..<auxiliary].joined(separator: " ")
            return subject.prefix(1).uppercased() + String(subject.dropFirst())
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func limitedChoiceDisplayLabel(_ label: String) -> String {
        let normalized = label.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > maxChoiceDisplayLength else { return normalized }
        return String(normalized.prefix(maxChoiceDisplayLength - 1)) + "…"
    }

    func permitsSubmission(
        hasFiles: Bool,
        direction: String,
        isSubmitting: Bool
    ) -> Bool {
        guard !isSubmitting else { return false }
        guard let intake = fileIntake else { return true }
        let hasText = !direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if intake.namePrompt != nil {
            return hasFiles && !AgentService.identitySlug(direction).isEmpty
        }
        if intake.completionLabel != nil {
            return textField != nil ? (hasFiles || hasText) : hasFiles
        }
        if !intake.required { return true }
        if textField != nil { return hasFiles || hasText }
        return hasFiles
    }

    func permitsCompletion(
        hasFiles: Bool,
        direction: String,
        isSubmitting: Bool
    ) -> Bool {
        guard !isSubmitting,
              let intake = fileIntake,
              !intake.required,
              intake.completionLabel != nil else { return false }
        return !hasFiles && direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasRepeatableIntakeDraft(hasFiles: Bool, direction: String) -> Bool {
        guard purpose == .workflowIntake,
              fileIntake?.namePrompt != nil,
              fileIntake?.completionLabel != nil else { return false }
        return hasFiles || !direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            let shortLabel = raw["shortLabel"] as? String
            switch (raw["type"] as? String) ?? "choices" {
            case "toggle":
                sections.append(Section(id: id, label: label, shortLabel: shortLabel,
                                        kind: .toggle(defaultOn: (raw["defaultOn"] as? Bool) ?? false)))
            case "choices":
                let options: [Choice] = ((raw["options"] as? [[String: Any]]) ?? []).enumerated().compactMap { i, opt in
                    guard let optLabel = opt["label"] as? String else { return nil }
                    return Choice(id: (opt["id"] as? String) ?? "option\(i)",
                                  label: optLabel,
                                  shortLabel: opt["shortLabel"] as? String,
                                  symbol: opt["symbol"] as? String,
                                  rangeRef: opt["rangeRef"] as? String)
                }
                // GUARDRAIL: enough to be a choice, few enough to scan. Set allowsCustom for open sets.
                guard options.count >= 2, options.count <= Self.maxOptionsPerSection else {
                    throw ToolError("show_dialog: choices section '\(id)' needs 2…\(Self.maxOptionsPerSection) options (set allowsCustom for an open 'Other…' field).")
                }
                sections.append(Section(id: id, label: label, shortLabel: shortLabel,
                                        kind: .choices(options: options,
                                                       multiSelect: (raw["multiSelect"] as? Bool) ?? false),
                                        allowsCustom: (raw["allowsCustom"] as? Bool) ?? false))
            case let other:
                throw ToolError("show_dialog: unknown section type '\(other)' (use 'choices' or 'toggle').")
            }
        }
        let textField = parseTextField(args)
        let fileIntake = try parseFileIntake(args["fileIntake"] as? [String: Any])
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
            projection: projection,
            workflowDecision: (args["workflowDecision"] as? String)
                .flatMap(WorkflowDecision.init(rawValue:))
        )
    }

    /// GUARDRAILS for agent-generated dialogs — the vocabulary is fixed and bounded so a card can never
    /// render as an overloaded or malformed wall of controls (schema-enforced, not prompt discipline).
    static let maxSections = 3
    static let maxOptionsPerSection = 8
    static let maxChoiceDisplayLength = 48

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

    private static func parseFileIntake(_ raw: [String: Any]?) throws -> FileIntake? {
        guard let raw else { return nil }
        let accept = ((raw["accept"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let prompt = (raw["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachAs = ((raw["attachAs"] as? String)?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        let namePrompt = (raw["namePrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard attachAs == nil, namePrompt == nil else {
            throw ToolError("show_dialog: workflow file intake is host-owned; omit attachAs/namePrompt and wait for the pack's intake card.")
        }
        // Workflow optionality belongs only to the pack manifest.
        let defaultRequired = true
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

extension AgentDialog.FileIntake {
    /// The UTTypes this intake accepts, for the native file panel. For "text" this adds the known
    /// document extensions (via `ClipType.documentExtensions`) so formats the system doesn't register
    /// as a shared UTType (.md/.markdown/.fountain) stay selectable, not just .txt.
    var allowedContentTypes: [UTType] {
        var types: [UTType] = []
        for token in accept {
            switch token.lowercased() {
            case "audio": types.append(.audio)
            case "video", "movie": types.append(.movie)
            case "image":
                types.append(
                    contentsOf: ProjectMediaExtensions.images.compactMap {
                        UTType(filenameExtension: $0)
                    }
                )
            case "text":
                // Plain text plus the known document extensions — NOT the broad `public.text` supertype,
                // which would also admit .json/.csv/.html. Stays in sync with ClipType.documentExtensions.
                types.append(.plainText)
                types.append(contentsOf: ClipType.documentExtensions.compactMap { UTType(filenameExtension: $0) })
            default:
                if let type = UTType(filenameExtension: token) { types.append(type) }
            }
        }
        return types
    }

    /// Whether a file at `url` is one this intake accepts — the ONE match used by the drop well, the
    /// native picker, and the in-card library picker. Kind tokens resolve through the app's own
    /// file-typing (`ClipType`) first, so a text format the system doesn't register as a UTType still
    /// counts; UTType conformance is the fallback for breadth and the no-restriction (empty) default.
    func accepts(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        for token in accept {
            switch token.lowercased() {
            case "audio": if ClipType(fileExtension: ext) == .audio { return true }
            case "video", "movie": if ClipType(fileExtension: ext) == .video { return true }
            case "image": if ClipType(fileExtension: ext) == .image { return true }
            case "text": if ClipType(fileExtension: ext) == .document { return true }
            default: if token.lowercased() == ext { return true }
            }
        }
        let allowed = allowedContentTypes
        guard !allowed.isEmpty else { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return allowed.contains { type.conforms(to: $0) }
    }
}
