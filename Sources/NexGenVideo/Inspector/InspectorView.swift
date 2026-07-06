import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(EditorViewModel.self) var editor

    enum ClipTab: String, Hashable {
        case text = "Text"
        case video = "Video"
        case effects = "Adjust"
        case audio = "Audio"
        case ai = "AI Edit"
    }

    enum AssetTab: String, Hashable {
        case details = "Details"
        case ai = "AI Edit"
    }

    @State private var preferredTab: ClipTab = .video
    @State private var preferredAssetTab: AssetTab = .details
    @State private var contextualPromptDraft = ""
    @State private var entityEditTarget: String?
    @State private var entityEditName = ""
    @State private var entityEditPrompt = ""
    @State private var entityEditTrait = ""
    @State private var transformExpanded = true
    @State var collapsedAdjustSections: Set<String> = ["Curves", "Color Wheels", "Hue Curves", "LUTs", "Effects"]
    @State var collapsedAdjustSubgroups: Set<String> = [
        "Detail", "Blur", "Motion Blur", "Vignette", "Film Grain", "Glow", "Chroma Key",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumbHeader
            Group {
                inspectorContent
            }
            .clipped()  // state views may never paint over the breadcrumb or pane edges
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: editor.selectedClipIds) { _, _ in
            if !editor.isMarqueeSelecting { resolvePreferredTab() }
            promoteSelection()
        }
        .onChange(of: editor.selectedMediaAssetIds) { _, _ in
            promoteSelection()
        }
        .onChange(of: editor.isMarqueeSelecting) { _, selecting in
            if !selecting { resolvePreferredTab() }
            promoteSelection()
        }
        .onChange(of: preferredTab) { _, newTab in
            if newTab != .video { editor.cropEditingActive = false }
        }
        .onAppear { promoteSelection() }
    }

    /// A multi-clip timeline selection — the one documented exception to the single-inspected-object
    /// rule. Batch editing across selected clips stays a first-class NLE feature.
    private var isMultiClipSelection: Bool {
        !editor.isMarqueeSelecting && editor.selectedClipIds.count > 1
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if editor.isMarqueeSelecting {
            // The breadcrumb already shows the live count; no body echo.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isMultiClipSelection {
            clipInspectorContent()
        } else if let object = editor.inspectedObject {
            objectInspector(object)
        } else {
            emptyInspectorState
        }
    }

    @ViewBuilder
    private func objectInspector(_ object: InspectedObject) -> some View {
        switch object {
        case .clip:
            clipInspectorContent()
        case .mediaAsset(let id):
            if let asset = mediaAsset(id: id) {
                mediaAssetInspectorContent(asset)
            } else {
                emptyInspectorState
            }
        case .entity(let ref):
            if let entity = editor.bible?.entity(ref) {
                entityInspectorContent(entity)
            } else {
                cockpitObjectTeaser(object)
            }
        case .look:
            if let look = editor.bible?.look, !look.isEmpty {
                lookInspectorContent(look)
            } else {
                cockpitObjectTeaser(object)
            }
        case .shot(let id):
            if let shot = editor.shotlist?.shots.first(where: { $0.id == id }) {
                shotInspectorContent(shot)
            } else {
                cockpitObjectTeaser(object)
            }
        case .shotUse:
            cockpitObjectTeaser(object)
        }
    }

    // MARK: - Entity / Look / Shot inspectors (read-only; editing lives in Phase C)

    private func entityInspectorContent(_ entity: any BibleEntity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                BibleEntityCard(entity: entity, projectDir: editor.studioProjectDir)
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Edit…") {
                        entityEditName = entity.name
                        entityEditPrompt = entity.visualPrompt
                        entityEditTrait = entity.hardRecognitionTrait
                        entityEditTarget = entity.id
                    }
                    .controlSize(.small)
                    .popover(isPresented: Binding(
                        get: { entityEditTarget == entity.id },
                        set: { if !$0 { entityEditTarget = nil } }
                    )) {
                        entityEditForm(entity)
                    }
                    scopedThreadButton
                }
                ledgerSection(for: .entity(BibleEntityRef(kind: entityKind(of: entity), id: entity.id)))
                usageSection(of: entity)
                contextualPromptField(placeholder: "Change \(entity.name)…")
                openInProjectLink(.bible)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lookInspectorContent(_ look: BibleLook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                metadataSection(title: "Look") {
                    ForEach(look.fields, id: \.label) { field in
                        plainMetadataRow(label: field.label, value: field.value)
                    }
                }
                ledgerSection(for: .look)
                openInProjectLink(.bible)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shotInspectorContent(_ shot: ShotSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                metadataSection(title: "Shot") {
                    plainMetadataRow(label: "ID", value: shot.id)
                    if let section = shot.section?.trimmingCharacters(in: .whitespaces), !section.isEmpty {
                        plainMetadataRow(label: "Section", value: section)
                    }
                    if !shot.type.isEmpty { plainMetadataRow(label: "Type", value: shot.type) }
                    if let framing = shot.framing, !framing.isEmpty {
                        plainMetadataRow(label: "Framing", value: framing)
                    }
                    if !shot.mood.isEmpty { plainMetadataRow(label: "Mood", value: shot.mood) }
                    if shot.durationS > 0 {
                        plainMetadataRow(label: "Duration", value: String(format: "%.1fs", shot.durationS))
                    }
                }
                if !shot.summaryText.isEmpty {
                    metadataSection(title: "Description") {
                        Text(shot.summaryText)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                if !shot.visualPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
                    metadataSection(title: "Visual Prompt") {
                        Text(shot.visualPrompt)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                ledgerSection(for: .shot(shot.id))
                shotProvenanceSections(shot.id)
                scopedThreadButton
                contextualPromptField(placeholder: "Change this shot…")
                openInProjectLink(.shotlist)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Shot↔entity provenance: which shots use this entity (click → inspect the shot).
    @ViewBuilder
    private func usageSection(of entity: any BibleEntity) -> some View {
        let graph = objectGraph
        let refs = BibleEntityKind.allCases.map { BibleEntityRef(kind: $0, id: entity.id) }
        let shots = refs.flatMap { graph.usage(of: $0) }
        if !shots.isEmpty {
            metadataSection(title: "Used in shots") {
                chipRow(shots.map { (graph.shotLabel($0) ?? $0, InspectedObject.shot($0)) })
            }
        }
    }

    /// Shot provenance: entities the shot uses + timeline clips that realize it.
    @ViewBuilder
    private func shotProvenanceSections(_ shotID: String) -> some View {
        let graph = objectGraph
        let entities = graph.entities(usedBy: shotID)
        if !entities.isEmpty {
            metadataSection(title: "Uses") {
                chipRow(entities.map { (graph.entityName($0) ?? $0.id, InspectedObject.entity($0)) })
            }
        }
        let clips = graph.clips(realizing: shotID)
        if !clips.isEmpty {
            metadataSection(title: "On timeline") {
                chipRow(clips.map { clipID in
                    let label = [graph.clipTrackLabels[clipID], graph.clipName(clipID)]
                        .compactMap(\.self).joined(separator: " · ")
                    return (label.isEmpty ? "Clip" : label, InspectedObject.clip(clipID))
                })
            }
        }
    }

    /// A wrapping row of navigable object chips (label → inspect target).
    private func chipRow(_ items: [(String, InspectedObject)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    if case .clip(let id) = item.1 { editor.selectedClipIds = [id] }
                    editor.inspectedObject = item.1
                } label: {
                    Text(item.0)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background { Capsule().fill(AppTheme.Background.raisedColor) }
                        .overlay(Capsule().strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The Intent Ledger on the object: tags always visible, locks marked — the object is the unit
    /// of memory (docs/UI_UX_CONCEPT.md §5). Read-only; the agent writes via its ledger tools.
    @ViewBuilder
    private func ledgerSection(for object: InspectedObject) -> some View {
        let attributes = editor.ledger?.attributes(for: object) ?? []
        if !attributes.isEmpty {
            metadataSection(title: "Intent") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    ForEach(attributes, id: \.key) { entry in
                        HStack(spacing: AppTheme.Spacing.xs) {
                            if entry.attribute.locked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: AppTheme.FontSize.micro))
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                            }
                            Text(entry.attribute.tag)
                                .font(.system(size: AppTheme.FontSize.xs, weight: entry.attribute.locked ? .semibold : .medium))
                                .foregroundStyle(entry.attribute.locked ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background { Capsule().fill(AppTheme.Background.raisedColor) }
                        .overlay(Capsule().strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
                        .help(ledgerHelp(entry.key, entry.attribute))
                    }
                }
            }
        }
    }

    private func ledgerHelp(_ key: String, _ attribute: LedgerAttribute) -> String {
        var parts = ["\(key): \(attribute.directive)"]
        if !attribute.source.isEmpty { parts.append("Source: \u{201C}\(attribute.source)\u{201D}") }
        if attribute.locked { parts.append("Locked — generation must honor this.") }
        return parts.joined(separator: "\n")
    }

    private func entityKind(of entity: any BibleEntity) -> BibleEntityKind {
        switch entity {
        case is BibleEnsemble: .ensemble
        case is BibleProp: .prop
        case is BibleLocation: .location
        default: .character
        }
    }

    /// A scoped, temporary thread about the inspected object (ladder rung 4): a fresh agent chat,
    /// the scope visible in the prefilled opener, context accumulating across turns.
    private var scopedThreadButton: some View {
        Button("Thread…") {
            editor.agentService.newChat()
            editor.agentService.draft = "About \(currentBreadcrumb.flatText): "
            editor.agentPanelVisible = true
        }
        .controlSize(.small)
        .help("Start a focused thread about this object")
    }

    /// Structured Bible editing: the form composes ONE precise agent command — the bible phase
    /// tooling stays the single writer, so schema/sheet invariants hold.
    private func entityEditForm(_ entity: any BibleEntity) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Edit \(entity.name)")
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            TextField("Name", text: $entityEditName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm))
            TextField("Visual prompt", text: $entityEditPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm))
                .lineLimit(3...6)
            TextField("Hard recognition trait", text: $entityEditTrait)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm))
            HStack {
                Spacer()
                Button("Apply via Agent") { applyEntityEdit(entity) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(width: 340)
    }

    private func applyEntityEdit(_ entity: any BibleEntity) {
        var changes: [String] = []
        func diff(_ field: String, new: String, old: String, clearable: Bool) {
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != old.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            if trimmed.isEmpty {
                // An emptied field is an explicit decision, not a no-op (names must stay non-empty).
                if clearable { changes.append("clear \(field)") }
            } else {
                changes.append("\(field) → \u{201C}\(trimmed)\u{201D}")
            }
        }
        diff("name", new: entityEditName, old: entity.name, clearable: false)
        diff("visual_prompt", new: entityEditPrompt, old: entity.visualPrompt, clearable: true)
        diff("hard_recognition_trait", new: entityEditTrait, old: entity.hardRecognitionTrait, clearable: true)
        entityEditTarget = nil
        guard !changes.isEmpty else { return }
        let kind = entityKind(of: entity).rawValue
        editor.agentService.send(
            text: "Update the Bible \(kind) \u{201C}\(entity.id)\u{201D}: "
                + changes.joined(separator: "; ")
                + ". Apply it through the bible tooling (keep schema + sheets consistent) and confirm the diff.",
            mentions: []
        )
        editor.agentPanelVisible = true
    }

    private func openInProjectLink(_ tab: CockpitTab) -> some View {
        Button("Open in Project") {
            editor.revealCockpit(tab)
        }
        .controlSize(.small)
    }

    // MARK: - Contextual one-shot prose (ladder rung 3 — docs/UI_UX_CONCEPT.md §4)

    /// A one-shot prompt bound to the inspected object: the prose goes to the agent as typed, and the
    /// scope chip above it shows what "this" resolves to — the inspected object IS the scope, so it's
    /// always visible whenever this field is (docs/UI_UX_CONCEPT.md §2.2). Not a mini-chat — the field
    /// clears on send and the Agent tab opens to show the work.
    private func contextualPromptField(placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if let hint = editor.selectionContextHint {
                ScopeChip(text: hint)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                TextField(placeholder, text: $contextualPromptDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .onSubmit(sendContextualPrompt)
                Button {
                    sendContextualPrompt()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: AppTheme.FontSize.lg))
                }
                .buttonStyle(.plain)
                .disabled(contextualPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func sendContextualPrompt() {
        let text = contextualPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        contextualPromptDraft = ""
        editor.agentService.send(text: text, mentions: [])
        editor.agentPanelVisible = true
    }

    /// Promote the current timeline/media selection to the app-global inspected object. A single clip or
    /// asset promotes; a marquee/multi/empty selection clears only a clip/asset object — a cockpit object
    /// (entity/shot/look) is left intact, since it was focused from the Project surface, not from here.
    private func promoteSelection() {
        if let object = editor.selectionInspectedObject {
            editor.inspectedObject = object
            return
        }
        // Selection cleared: keep a cockpit object (entity/shot/look), drop a clip/asset object.
        guard let current = editor.inspectedObject else { return }
        switch current {
        case .clip, .mediaAsset:
            editor.inspectedObject = nil
        case .entity, .look, .shot, .shotUse:
            break
        }
    }

    private func mediaAsset(id: String) -> MediaAsset? {
        editor.mediaAssets.first { $0.id == id }
    }

    // MARK: - Breadcrumb header

    /// The read model over everything inspectable: engine snapshots (Bible entities, shots) plus the
    /// app-owned timeline and media — so breadcrumbs resolve real names (`Character › Mara`).
    private var objectGraph: ObjectGraph {
        var names: [String: String] = [:]
        var paths: [String: String] = [:]
        for asset in editor.mediaAssets {
            names[asset.id] = asset.name
            paths[asset.id] = asset.url.path
        }
        return ObjectGraph.from(
            bible: editor.bible,
            shotlist: editor.shotlist,
            timeline: editor.timeline,
            assetNames: names,
            assetPaths: paths
        )
    }

    private var currentBreadcrumb: ObjectBreadcrumb {
        if editor.isMarqueeSelecting {
            return ObjectBreadcrumb(segments: [.init(label: "\(editor.selectedClipIds.count) selected", object: nil)])
        }
        if isMultiClipSelection {
            return ObjectBreadcrumb(segments: [.init(label: "\(editor.selectedClipIds.count) clips", object: nil)])
        }
        if let object = editor.inspectedObject {
            return objectGraph.breadcrumb(for: object)
        }
        return ObjectBreadcrumb(segments: [])
    }

    /// A plain label, not a control bar: the breadcrumb *describes* the inspected object (context),
    /// it doesn't navigate — so it wears no raised band and no border (docs/UI_UX_CONCEPT.md §3).
    @ViewBuilder
    private var breadcrumbHeader: some View {
        let crumb = currentBreadcrumb
        if !crumb.segments.isEmpty {
            HStack(spacing: AppTheme.Spacing.xxs) {
                ForEach(Array(crumb.segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    let isLast = index == crumb.segments.count - 1
                    let label = Text(segment.label)
                        .font(.system(size: AppTheme.FontSize.xs, weight: isLast ? .semibold : .regular))
                        .foregroundStyle(isLast ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                    // Parent segments that resolve to an object navigate to it — the graph's payoff.
                    if !isLast, let target = segment.object {
                        Button { editor.inspectedObject = target } label: { label }
                            .buttonStyle(.plain)
                    } else {
                        label
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.top, AppTheme.Spacing.smMd)
            .padding(.bottom, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyInspectorState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Spacer()
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: AppTheme.FontSize.xl))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text("Select a clip or asset to inspect it")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppTheme.Spacing.lg)
    }

    /// Entity/shot/look objects are worked on in the Project cockpit; the Inspector offers the jump.
    /// (Dedicated entity/shot inspectors are Phase B.)
    private func cockpitObjectTeaser(_ object: InspectedObject) -> some View {
        let target: CockpitTab = switch object {
        case .shot, .shotUse: .shotlist
        default: .bible
        }
        return VStack(spacing: AppTheme.Spacing.smMd) {
            Spacer()
            Text(currentBreadcrumb.flatText)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .multilineTextAlignment(.center)
            Button("Open in Project") {
                editor.revealCockpit(target)
            }
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppTheme.Spacing.lg)
    }


    private func resolvePreferredTab() {
        let isSingleText = selectedVisualClips.count + selectedAudioClips.count == 1
            && selectedVisualClip?.mediaType == .text
        if isSingleText {
            preferredTab = .text
        } else if preferredTab == .text {
            preferredTab = .video
        }
        editor.cropEditingActive = false
    }

    // MARK: - Metadata rows (shared by the clip/asset inspectors)

    private func metadataSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            VStack(spacing: AppTheme.Spacing.sm) {
                content()
            }
        }
    }

    private func plainMetadataRow(
        label: String,
        value: String,
        valueHelp: String? = nil,
        truncate: Text.TruncationMode = .tail
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize()
            Spacer()
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(truncate)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .help(valueHelp ?? value)
                .padding(.horizontal, AppTheme.Spacing.xs)
        }
        .frame(height: AppTheme.IconSize.md)
    }

    // MARK: - Clip Inspector

    private var availableTabs: [ClipTab] {
        let visuals = selectedVisualClips
        let audios = selectedAudioClips
        let nonText = nonTextVisualClips
        let isSingle = visuals.count + audios.count == 1
        let isSingleText = isSingle && visuals.first?.mediaType == .text

        var tabs: [ClipTab] = []
        if isSingleText { tabs.append(.text) }
        if !nonText.isEmpty {
            tabs.append(.video)
            tabs.append(.effects)
        }
        if !audios.isEmpty { tabs.append(.audio) }
        if aiEditEligible { tabs.append(.ai) }
        return tabs
    }

    /// True when the selection resolves to a single AI-editable visual clip.
    /// A linked video+audio pair counts as one
    private var aiEditEligible: Bool {
        let visuals = selectedVisualClips
        let audios = selectedAudioClips
        guard visuals.count == 1, resolvedClipAsset != nil else { return false }
        if audios.isEmpty { return true }
        let partners = Set(editor.linkedPartnerIds(of: visuals[0].id))
        return audios.allSatisfy { partners.contains($0.id) }
    }

    /// Tab the view actually renders (preferred if valid, else first available).
    private var activeTab: ClipTab? {
        let tabs = availableTabs
        return tabs.contains(preferredTab) ? preferredTab : tabs.first
    }

    /// The visual-or-image MediaAsset backing the currently selected visual clip.
    private var resolvedClipAsset: MediaAsset? {
        guard let clip = selectedVisualClip, clip.mediaType.isVisual else { return nil }
        return editor.mediaAssets.first { $0.id == clip.mediaRef }
    }

    var nonTextVisualClips: [Clip] {
        selectedVisualClips.filter { $0.mediaType != .text }
    }

    @ViewBuilder
    private func clipInspectorContent() -> some View {
        let tabs = availableTabs
        VStack(spacing: 0) {
            if tabs.count > 1 {
                tabBar(tabs)
            }
            Group {
                if activeTab == .ai, let asset = resolvedClipAsset {
                    AIEditTab(asset: asset, clipId: selectedVisualClip?.id)
                } else if activeTab == .effects {
                    ScrollView { effectsTabContent() }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                            switch activeTab {
                            case .text:
                                if let v = selectedVisualClip, v.mediaType == .text { TextTab(clip: v) }
                            case .video:
                                videoTabContent()
                            case .audio:
                                audioTabContent()
                            case .effects, .ai, .none:
                                EmptyView()
                            }
                        }
                        .padding(AppTheme.Spacing.lg)
                    }
                }
            }
        }
    }

    private func tabBar(_ tabs: [ClipTab]) -> some View {
        genericTabBar(titles: tabs.map(\.rawValue), selected: activeTab?.rawValue) { title in
            if let tab = tabs.first(where: { $0.rawValue == title }) { preferredTab = tab }
        }
    }

    private func assetTabBar(_ tabs: [AssetTab]) -> some View {
        genericTabBar(titles: tabs.map(\.rawValue), selected: preferredAssetTab.rawValue) { title in
            if let tab = tabs.first(where: { $0.rawValue == title }) { preferredAssetTab = tab }
        }
    }

    private func genericTabBar(
        titles: [String], selected: String?,
        raisedBackground: Bool = false,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        SegmentedTabBar(
            titles: titles, selected: selected,
            raisedBackground: raisedBackground,
            accentedTitles: [ClipTab.ai.rawValue],
            onSelect: onSelect
        )
    }

    @ViewBuilder
    private func videoTabContent() -> some View {
        let clips = nonTextVisualClips
        let single = clips.count == 1 ? clips.first : nil
        let kfVisible = single != nil && editor.keyframesPanelVisible

        if let clip = single, kfVisible {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    transformSection(clips: clips)
                    speedSection(clips: clips + selectedAudioClips)
                        .padding(.trailing, KeyframesMetrics.controlsColumnWidth + AppTheme.Spacing.sm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, AppTheme.Spacing.sm)
                Divider()
                KeyframesPanel(clip: clip)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, AppTheme.Spacing.sm)
            }
        } else {
            transformSection(clips: clips)
            speedSection(clips: clips + selectedAudioClips)
        }

        keyframesToggleBar(enabled: single != nil)
    }

    func keyframesToggleBar(enabled: Bool) -> some View {
        let on = editor.keyframesPanelVisible
        return HStack {
            Spacer()
            Button {
                editor.keyframesPanelVisible.toggle()
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: on ? "diamond.fill" : "diamond")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    Text("Keyframes")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                }
                .foregroundStyle(on ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.vertical, AppTheme.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .help(enabled ? (on ? "Hide keyframe timeline" : "Show keyframe timeline") : "Select a single clip to enable")
        }
    }

    @ViewBuilder
    func speedSection(clips: [Clip]) -> some View {
        if !clips.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                sectionTitleLabel(title: "Playback")
                propertyRow(label: "Speed") {
                    ScrubbableNumberField(
                        value: sharedClipValue(clips) { $0.speed },
                        range: 0.25...4.0,
                        format: "%.2f",
                        valueSuffix: "x",
                        dragSensitivity: 0.01,
                        fieldWidth: 50,
                        onChanged: { newVal in
                            for c in clips { editor.applyClipSpeed(clipId: c.id, newSpeed: newVal) }
                        }
                    ) { newVal in
                        editor.commitClipSpeed(ids: clips.map(\.id), newSpeed: newVal)
                    }
                }
            }
        }
    }

    func commitToClips(_ clips: [Clip], actionName: String, _ commit: (Clip) -> Void) {
        editor.undoManager?.beginUndoGrouping()
        for c in clips { commit(c) }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName(actionName)
    }

    // MARK: - Transform Section

    @ViewBuilder
    private func transformSection(clips: [Clip]) -> some View {
        let single = clips.count == 1 ? clips.first : nil
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            transformHeader(clips: clips)
                .frame(height: KeyframesMetrics.headerHeight, alignment: .leading)
            if transformExpanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    animatableRow(label: "Position", clipId: single?.id, property: .position) {
                        InspectorPositionFields(clips: clips)
                    }
                    animatableRow(label: "Scale", clipId: single?.id, property: .scale) {
                        scaleScrubField(clips: clips)
                    }
                    animatableRow(label: "Rotation", clipId: single?.id, property: .rotation) {
                        rotationScrubField(clips: clips)
                    }
                    animatableRow(label: "Opacity", clipId: single?.id, property: .opacity) {
                        opacityScrubField(clips: clips)
                    }
                    cropRow(single: single)
                    flipRow(clips: clips)
                }
                .padding(.leading, sectionContentIndent)
            }
        }
    }

    /// Property row with an optional keyframe stamp button after the value field.
    @ViewBuilder
    func animatableRow<Fields: View>(
        label: String,
        clipId: String?,
        property: AnimatableProperty,
        @ViewBuilder fields: () -> Fields
    ) -> some View {
        propertyRow(label: label) {
            HStack(spacing: AppTheme.Spacing.sm) {
                fields()
                if let clipId {
                    keyframeControls(clipId: clipId, property: property)
                }
            }
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }

    private func keyframeControls(clipId: String, property: AnimatableProperty) -> some View {
        let frame = editor.activeFrame
        let inRange = editor.clipFor(id: clipId)?.contains(timelineFrame: frame) ?? false
        let onKeyframe = editor.hasKeyframe(clipId: clipId, property: property, at: frame)
        let prev = editor.previousKeyframeFrame(clipId: clipId, property: property, before: frame)
        let next = editor.nextKeyframeFrame(clipId: clipId, property: property, after: frame)
        return HStack(spacing: 0) {
            keyframeNavButton(systemName: "chevron.left", help: "Go to previous keyframe", enabled: prev != nil) {
                if let f = prev { editor.seekToFrame(f) }
            }
            Button {
                if onKeyframe {
                    editor.removeKeyframe(clipId: clipId, property: property, at: frame)
                } else {
                    editor.stampKeyframe(clipId: clipId, property: property, frame: frame)
                }
            } label: {
                Image(systemName: onKeyframe ? "diamond.fill" : "diamond")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(onKeyframe ? AppTheme.Accent.timecodeColor : AppTheme.Text.tertiaryColor)
                    .frame(width: KeyframesMetrics.stampButtonWidth, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!inRange)
            .opacity(inRange ? 1 : 0.4)
            .help(!inRange ? "Move playhead inside the clip"
                  : onKeyframe ? "Remove keyframe at playhead"
                  : "Add keyframe at playhead")
            keyframeNavButton(systemName: "chevron.right", help: "Go to next keyframe", enabled: next != nil) {
                if let f = next { editor.seekToFrame(f) }
            }
        }
    }

    private func keyframeNavButton(
        systemName: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: KeyframesMetrics.navButtonWidth, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(help)
    }

    /// Rows sit flush-left under their uppercase section header.
    var sectionContentIndent: CGFloat { 0 }

    private func transformHeader(clips: [Clip]) -> some View {
        collapsibleHeader(
            title: "Transform",
            expanded: transformExpanded,
            onToggle: { transformExpanded.toggle() },
            resetHelp: transformExpanded ? "Reset transform" : nil,
            onReset: transformExpanded ? {
                commitToClips(clips, actionName: "Reset Transform") { c in
                    editor.commitClipProperty(clipId: c.id) {
                        $0.transform = Transform()
                        $0.opacity = 1
                        $0.opacityTrack = nil
                        $0.positionTrack = nil
                        $0.scaleTrack = nil
                        $0.rotationTrack = nil
                        $0.fadeInFrames = 0
                        $0.fadeOutFrames = 0
                        $0.fadeInInterpolation = .linear
                        $0.fadeOutInterpolation = .linear
                    }
                }
            } : nil
        )
    }

    @ViewBuilder
    private func scaleScrubField(clips: [Clip]) -> some View {
        ScrubbableNumberField(
            value: sharedClipValue(clips) { $0.sizeAt(frame: editor.activeFrame).width },
            range: 0.01...(.infinity),
            displayMultiplier: 100,
            format: "%.0f",
            valueSuffix: "%",
            fieldWidth: 50,
            onChanged: { newVal in
                for c in clips { editor.applyScale(clipId: c.id, newScale: newVal) }
            }
        ) { newVal in
            editor.undoManager?.beginUndoGrouping()
            for c in clips { editor.commitScale(clipId: c.id, newScale: newVal) }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Change Scale")
        }
    }

    @ViewBuilder
    private func rotationScrubField(clips: [Clip]) -> some View {
        ScrubbableNumberField(
            value: sharedClipValue(clips) { $0.rotationAt(frame: editor.activeFrame) },
            range: -3600...3600,
            displayMultiplier: 1,
            format: "%.0f",
            valueSuffix: "°",
            fieldWidth: 50,
            onChanged: { newVal in
                for c in clips { editor.applyRotation(clipId: c.id, valueDeg: newVal) }
            }
        ) { newVal in
            editor.undoManager?.beginUndoGrouping()
            for c in clips { editor.commitRotation(clipId: c.id, valueDeg: newVal) }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Change Rotation")
        }
    }

    @ViewBuilder
    private func opacityScrubField(clips: [Clip]) -> some View {
        ScrubbableNumberField(
            value: sharedClipValue(clips) { $0.rawOpacityAt(frame: editor.activeFrame) },
            range: 0...1,
            displayMultiplier: 100,
            format: "%.0f",
            valueSuffix: "%",
            fieldWidth: 50,
            onChanged: { newVal in
                for c in clips { editor.applyOpacity(clipId: c.id, value: newVal) }
            }
        ) { newVal in
            editor.undoManager?.beginUndoGrouping()
            for c in clips { editor.commitOpacity(clipId: c.id, value: newVal) }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Change Opacity")
        }
    }

    // MARK: - Section helpers

    private func collapsibleHeader(
        title: String,
        expanded: Bool,
        onToggle: @escaping () -> Void,
        resetHelp: String? = nil,
        onReset: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Button(action: onToggle) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    sectionTitleLabel(title: title)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if let onReset {
                resetButton(onReset: onReset, help: resetHelp)
            }
        }
    }

    func sectionTitleLabel(title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.Text.mutedColor)
            .fixedSize()
    }

    func resetButton(onReset: @escaping () -> Void, help: String?) -> some View {
        Button(action: onReset) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(help ?? "Reset")
    }

    func propertyRow<Trailing: View>(
        label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .fixedSize()
            Spacer()
            trailing()
        }
    }

    // MARK: - Flip

    @ViewBuilder
    private func flipRow(clips: [Clip]) -> some View {
        let activeH = clips.first?.transform.flipHorizontal ?? false
        let activeV = clips.first?.transform.flipVertical ?? false
        propertyRow(label: "Flip") {
            HStack(spacing: AppTheme.Spacing.xs) {
                iconToggleButton(
                    systemName: "arrow.left.and.right",
                    isOn: activeH,
                    help: activeH ? "Remove horizontal flip" : "Flip horizontally"
                ) {
                    let newValue = !activeH
                    commitToClips(clips, actionName: "Flip Horizontal") { c in
                        editor.commitClipProperty(clipId: c.id) { $0.transform.flipHorizontal = newValue }
                    }
                }
                iconToggleButton(
                    systemName: "arrow.up.and.down",
                    isOn: activeV,
                    help: activeV ? "Remove vertical flip" : "Flip vertically"
                ) {
                    let newValue = !activeV
                    commitToClips(clips, actionName: "Flip Vertical") { c in
                        editor.commitClipProperty(clipId: c.id) { $0.transform.flipVertical = newValue }
                    }
                }
            }
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }

    private func iconToggleButton(
        systemName: String,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(isOn ? AppTheme.Accent.primary : AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(Color.white.opacity(isOn ? AppTheme.Opacity.subtle : 0))
                )
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Crop

    @ViewBuilder
    private func cropRow(single: Clip?) -> some View {
        let editing = editor.cropEditingActive && single != nil
        let disabled = single == nil
        propertyRow(label: "Crop") {
            HStack(spacing: AppTheme.Spacing.sm) {
                iconToggleButton(
                    systemName: "crop",
                    isOn: editing,
                    help: disabled ? "Crop applies to one clip at a time"
                          : editing ? "Stop editing crop on canvas"
                          : "Edit crop on canvas"
                ) {
                    editor.cropEditingActive.toggle()
                }
                .disabled(disabled)
                cropMenu(single: single)
                if let cid = single?.id {
                    keyframeControls(clipId: cid, property: .crop)
                }
            }
        }
        .frame(height: KeyframesMetrics.rowHeight)
        .opacity(disabled ? 0.4 : 1)
    }

    @ViewBuilder
    private func cropMenu(single: Clip?) -> some View {
        let active = editor.cropAspectLock
        Menu {
            ForEach(CropAspectLock.allCases, id: \.self) { preset in
                Button {
                    if let clip = single { applyCropPreset(preset, on: clip) }
                } label: {
                    if preset == active {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(active.label)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(single == nil)
        .help("Choose a crop aspect")
    }

    private func applyCropPreset(_ preset: CropAspectLock, on clip: Clip) {
        editor.cropAspectLock = preset
        switch preset {
        case .free:
            // Don't mutate crop; user keeps current shape and drags freely.
            break
        case .original:
            editor.commitCrop(clipId: clip.id, newCrop: Crop())
        default:
            guard let target = preset.pixelAspect else { return }
            editor.commitCrop(clipId: clip.id, newCrop: editor.cropFittingAspect(for: clip, targetPixelAspect: target))
        }
    }

    // MARK: - Media Asset Inspector

    @ViewBuilder
    private func mediaAssetInspectorContent(_ asset: MediaAsset) -> some View {
        if asset.type.isVisual {
            VStack(spacing: 0) {
                assetTabBar([.details, .ai])
                if preferredAssetTab == .ai {
                    AIEditTab(asset: asset)
                } else {
                    assetDetailsContent(asset)
                }
            }
        } else {
            assetDetailsContent(asset)
        }
    }

    @ViewBuilder
    private func assetDetailsContent(_ asset: MediaAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                assetIdentityHeader(asset)

                fileSection(asset)

                if let gen = asset.generationInput {
                    if GenerationReferencesStrip.hasResolvableReferences(gen, in: editor.mediaAssets) {
                        metadataSection(title: "References") {
                            GenerationReferencesStrip(generationInput: gen)
                        }
                    }

                    metadataSection(title: "Generated") {
                        plainMetadataRow(label: "Model", value: ModelRegistry.displayName(for: gen.model))
                        if !gen.aspectRatio.isEmpty {
                            plainMetadataRow(label: "Aspect Ratio", value: gen.aspectRatio)
                        }
                        if let resolution = gen.resolution {
                            plainMetadataRow(label: "Resolution", value: resolution)
                        }
                        if gen.duration > 0 {
                            plainMetadataRow(label: "Duration", value: "\(gen.duration)s")
                        }
                    }

                    if !gen.prompt.isEmpty {
                        promptSection(prompt: gen.prompt)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func fileSection(_ asset: MediaAsset) -> some View {
        metadataSection(title: "File") {
            plainMetadataRow(label: "Type", value: asset.type.trackLabel)
            if asset.type != .audio, let width = asset.sourceWidth, let height = asset.sourceHeight {
                plainMetadataRow(label: "Dimensions", value: "\(width) × \(height)")
            }
            if asset.duration > 0 && asset.type != .image {
                plainMetadataRow(label: "Duration", value: formatDuration(asset.duration))
            }
            if let fileSize = fileSize(for: asset.url) {
                plainMetadataRow(label: "Size", value: fileSize)
            }
            plainMetadataRow(
                label: "Path",
                value: asset.url.path,
                truncate: .middle
            )
        }
    }

    @ViewBuilder
    private func assetIdentityHeader(_ asset: MediaAsset) -> some View {
        // The breadcrumb header already names the asset; surface only the AI-generated badge here.
        if asset.generationInput != nil {
            HStack(spacing: AppTheme.Spacing.sm) {
                aiBadge
                Spacer(minLength: 0)
            }
        }
    }

    private var aiBadge: some View {
        Text("AI")
            .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.aiGradient)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(Color.white.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline)
            )
    }

    private func promptSection(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("PROMPT")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Spacer()
                PromptCopyButton(text: prompt)
            }
            Text(prompt)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metadataRow(_ icon: String, label: String, value: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(width: AppTheme.IconSize.xs)
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer()
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }


    // MARK: - Helpers

    private var selectedVisualClips: [Clip] {
        guard !editor.selectedClipIds.isEmpty else { return [] }
        var out: [Clip] = []
        for track in editor.timeline.tracks {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) && clip.mediaType.isVisual {
                out.append(clip)
            }
        }
        return out
    }

    var selectedAudioClips: [Clip] {
        guard !editor.selectedClipIds.isEmpty else { return [] }
        var out: [Clip] = []
        for track in editor.timeline.tracks {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) && clip.mediaType == .audio {
                out.append(clip)
            }
        }
        return out
    }

    private var selectedVisualClip: Clip? { selectedVisualClips.first }
    private var selectedAudioClip: Clip? { selectedAudioClips.first }

    private func fileSize(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

func sharedClipValue<T: Equatable>(_ clips: [Clip], _ extract: (Clip) -> T) -> T? {
    guard let first = clips.first else { return nil }
    let v = extract(first)
    for c in clips.dropFirst() where extract(c) != v { return nil }
    return v
}

// MARK: - Volume Scale

/// Maps a linear amplitude multiplier to dB for the volume slider.
/// Below the floor we snap to true 0 (hard mute) and render "-∞ dB".
enum VolumeScale {
    static let floorDb: Double = -60
    static let ceilingDb: Double = 15

    static func dbFromLinear(_ linear: Double) -> Double {
        guard linear > 0 else { return floorDb }
        return min(ceilingDb, max(floorDb, 20 * log10(linear)))
    }

    static func linearFromDb(_ db: Double) -> Double {
        guard db > floorDb else { return 0 }
        return pow(10, min(db, ceilingDb) / 20)
    }
}

struct PromptCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy prompt")
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}
