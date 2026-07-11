import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentInputBox<LeadingTools: View>: View {
    @Environment(EditorViewModel.self) var editor
    @Binding var draft: String
    @Binding var mentions: [AgentMention]
    let isSending: Bool
    let canSend: Bool
    /// While a dialog card (or spend approval) is open above the composer, the composer is the second,
    /// competing input surface — so it's locked. One active input at a time: answer the card first.
    let blocked: Bool
    let blockedHint: String
    let onSend: () -> Void
    let onCancel: () -> Void
    let leadingTools: LeadingTools

    init(
        draft: Binding<String>,
        mentions: Binding<[AgentMention]>,
        isSending: Bool,
        canSend: Bool,
        blocked: Bool = false,
        blockedHint: String = "",
        onSend: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder leadingTools: () -> LeadingTools
    ) {
        self._draft = draft
        self._mentions = mentions
        self.isSending = isSending
        self.canSend = canSend
        self.blocked = blocked
        self.blockedHint = blockedHint
        self.onSend = onSend
        self.onCancel = onCancel
        self.leadingTools = leadingTools()
    }

    @FocusState private var focused: Bool
    @State private var mentionQuery: String? = nil
    @State private var highlightedMentionIndex: Int = 0
    @State private var mentionTab: MentionTab = .all
    @State private var mentionScrollTick: Int = 0
    @State private var isDropTargeted = false
    @State private var textEditorID = UUID()
    @Namespace private var sendStopNamespace

    /// User-set input height (drag the top edge), persisted across sessions.
    @AppStorage("agentComposerHeight") private var composerHeight: Double = Double(AppTheme.ComponentSize.agentComposerMinHeight)
    @State private var resizeStartHeight: Double?

    private var clampedComposerHeight: CGFloat {
        CGFloat(min(Double(AppTheme.ComponentSize.agentComposerMaxHeight),
                    max(Double(AppTheme.ComponentSize.agentComposerMinHeight), composerHeight)))
    }

    private var showMentionPicker: Bool { mentionQuery != nil }

    private var mentionCandidates: [MediaAsset] {
        let q = (mentionQuery ?? "").lowercased()
        let typed = mentionTab.clipType.map { t in editor.mediaAssets.filter { $0.type == t } }
            ?? editor.mediaAssets
        let matched = q.isEmpty ? typed : typed.filter { $0.mentionDisplayName.lowercased().contains(q) }
        return Array(matched.prefix(50))
    }

    var body: some View {
        VStack(spacing: 0) {
            textField
                .popover(isPresented: Binding(
                    get: { showMentionPicker && !blocked },
                    set: { if !$0 { mentionQuery = nil } }
                ), attachmentAnchor: .point(.topLeading), arrowEdge: .top) {
                    MentionPopover(
                        query: mentionQuery ?? "",
                        candidates: mentionCandidates,
                        highlightedIndex: $highlightedMentionIndex,
                        tab: $mentionTab,
                        scrollTick: mentionScrollTick,
                        onPick: { asset in pickMention(asset) }
                    )
                }
                .onChange(of: mentionTab) { _, _ in highlightedMentionIndex = 0 }
            bottomBar
        }
        .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong)
                        : focused ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium)
                        : Color.white.opacity(AppTheme.Opacity.hint),
                    lineWidth: (focused || isDropTargeted) ? AppTheme.BorderWidth.thin : AppTheme.BorderWidth.hairline
                )
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) { resizeHandle }
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: blocked ? nil : $isDropTargeted, perform: handleDrop)
        .onChange(of: editor.agentService.focusInputRequestTick) { _, _ in
            Task { @MainActor in focused = true }
        }
        // A dialog card opened above: the composer is locked, so drop the mention popover and clear
        // any hover-drop highlight — no second input surface competes with the card.
        .onChange(of: blocked) { _, isBlocked in
            if isBlocked { mentionQuery = nil; isDropTargeted = false }
        }
    }

    /// Invisible grab strip on the box's top edge: drag up to grow, down to shrink,
    /// clamped to the min/max. The resize cursor is the affordance.
    private var resizeHandle: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: AppTheme.ComponentSize.agentComposerGrabHeight)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = resizeStartHeight ?? Double(clampedComposerHeight)
                        if resizeStartHeight == nil { resizeStartHeight = base }
                        composerHeight = min(Double(AppTheme.ComponentSize.agentComposerMaxHeight),
                                             max(Double(AppTheme.ComponentSize.agentComposerMinHeight),
                                                 base - value.translation.height))
                    }
                    .onEnded { _ in resizeStartHeight = nil }
            )
            .help("Drag to resize")
    }

    private var textField: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .id(textEditorID)
                .font(.body)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.top, AppTheme.Spacing.smMd)
                .padding(.bottom, AppTheme.Spacing.xs)
                .focused($focused)
                .frame(height: clampedComposerHeight)
                .disabled(blocked)
                .opacity(blocked ? AppTheme.Opacity.strong : 1)
                .onChange(of: draft) { old, new in
                    updateMentionQuery(from: new)
                    if !old.isEmpty && new.isEmpty {
                        let wasFocused = focused
                        textEditorID = UUID()
                        if wasFocused {
                            Task { @MainActor in focused = true }
                        }
                    }
                }
                .onPasteCommand(of: [.fileURL, .image, .png, .jpeg, .tiff], perform: handlePaste)
                .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
                // NSTextView eats Tab before the general onKeyPress fires.
                .onKeyPress(.tab, phases: .down) { press in
                    guard showMentionPicker else { return .ignored }
                    cycleMentionTab(reverse: press.modifiers.contains(.shift))
                    return .handled
                }

            if draft.isEmpty {
                Text(blocked ? (blockedHint.isEmpty ? "Answer the card above to continue" : blockedHint)
                             : "Ask, or type @ to reference media")
                    .font(.body)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.top, AppTheme.Spacing.mdLg)
                    .allowsHitTesting(false)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(AppTheme.Opacity.hint))
                .frame(height: AppTheme.BorderWidth.hairline)
            HStack(spacing: AppTheme.Spacing.md) {
                attachButton
                leadingTools
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: AppTheme.Spacing.xs) {
                    sendStopButton
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
    }

    @ViewBuilder
    private var sendStopButton: some View {
        if isSending {
            Button(action: onCancel) {
                Image(systemName: "stop.fill")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .bold))
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(AppTheme.Text.secondaryColor)
            .glassEffectID("sendStop", in: sendStopNamespace)
            .help("Stop")
            .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .bold))
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(AppTheme.Accent.primary)
            .glassEffectID("sendStop", in: sendStopNamespace)
            .disabled(!canSend || blocked)
            .opacity(canSend && !blocked ? 1 : AppTheme.Opacity.strong)
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// The reliable way to bring a local file (a song, a clip, a still) into the chat — a real file
    /// picker, since dropping onto the text area is eaten by the text editor and the agent can't open
    /// one itself. Imports each pick as a media asset and @mentions it, exactly like drop/paste.
    private var attachButton: some View {
        Button(action: presentAttachPanel) {
            Image(systemName: "paperclip")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(blocked)
        .opacity(blocked ? AppTheme.Opacity.strong : 1)
        .help("Attach a file — song, video, or image")
    }

    private func presentAttachPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie, .image]
        panel.prompt = "Attach"
        panel.message = "Choose a song, video, or image to bring into the project."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let asset = editor.addMediaAsset(from: url) {
                editor.agentService.attachMention(for: asset)
            }
        }
    }

    private func cycleMentionTab(reverse: Bool) {
        let tabs = MentionTab.allCases
        let step = reverse ? -1 : 1
        let current = tabs.firstIndex(of: mentionTab) ?? 0
        mentionTab = tabs[(current + step + tabs.count) % tabs.count]
        mentionScrollTick &+= 1
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if showMentionPicker {
            let isArrow = press.key == .upArrow || press.key == .downArrow
            if press.phase == .repeat && !isArrow { return .handled }
            let candidates = mentionCandidates
            switch press.key {
            case .upArrow:
                moveMentionHighlight(by: -1, within: candidates)
                return .handled
            case .downArrow:
                moveMentionHighlight(by: 1, within: candidates)
                return .handled
            case .return:
                if candidates.indices.contains(highlightedMentionIndex) {
                    pickMention(candidates[highlightedMentionIndex])
                }
                return .handled
            case .escape:
                mentionQuery = nil
                return .handled
            default:
                return .ignored
            }
        }

        guard press.phase == .down else { return .ignored }
        if press.key == .return, !press.modifiers.contains(.shift), canSend {
            onSend()
            return .handled
        }
        return .ignored
    }

    private func moveMentionHighlight(by delta: Int, within candidates: [MediaAsset]) {
        guard !candidates.isEmpty else { return }
        let next = min(candidates.count - 1, max(0, highlightedMentionIndex + delta))
        guard next != highlightedMentionIndex else { return }
        highlightedMentionIndex = next
        mentionScrollTick &+= 1
    }

    private func updateMentionQuery(from text: String) {
        let newQuery: String? = {
            guard let lastAt = text.lastIndex(of: "@") else { return nil }
            let after = text[text.index(after: lastAt)...]
            if after.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
            if lastAt > text.startIndex {
                let prev = text[text.index(before: lastAt)]
                if !prev.isWhitespace && !prev.isNewline { return nil }
            }
            return String(after)
        }()

        guard newQuery != mentionQuery else { return }
        mentionQuery = newQuery
        highlightedMentionIndex = 0
    }

    private func pickMention(_ asset: MediaAsset) {
        let displayName = AgentService.disambiguatedMentionName(for: asset, existing: mentions)
        if let lastAt = draft.lastIndex(of: "@") {
            let prefix = draft[..<lastAt]
            draft = String(prefix) + "@\(displayName) "
        } else {
            draft += "@\(displayName) "
        }
        mentions.append(AgentMention(
            displayName: displayName,
            mediaRef: asset.id,
            type: asset.type
        ))
        mentionQuery = nil
        highlightedMentionIndex = 0
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !blocked else { return false }  // locked while a dialog card owns the input
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if let asset = editor.addMediaAsset(from: url) {
                        editor.agentService.attachMention(for: asset)
                    }
                }
            }
        }
        return handled
    }

    private func handlePaste(_: [NSItemProvider]) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            urls.compactMap { editor.addMediaAsset(from: $0) }
                .forEach { editor.agentService.attachMention(for: $0) }
            return
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            if let data = pb.data(forType: type),
               let asset = editor.importPastedImageData(data, fileExtension: ext) {
                editor.agentService.attachMention(for: asset)
                return
            }
        }
        // onPasteCommand swallows the default paste, so echo text manually.
        if let text = pb.string(forType: .string) { draft += text }
    }
}
