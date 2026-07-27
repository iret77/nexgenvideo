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
    @State private var showReferencePicker = false
    @State private var attachmentError: String?
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

    private var pickableLibraryAssets: [MediaAsset] {
        editor.agentPickableMediaAssets
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
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
                        onPick: { asset in pickMention(asset) },
                        onUpload: { uploadFromMention() }
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
                        : AppTheme.Border.subtleColor,
                    lineWidth: (focused || isDropTargeted) ? AppTheme.BorderWidth.thin : AppTheme.BorderWidth.hairline
                )
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) { resizeHandle }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: focused)
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: blocked ? nil : $isDropTargeted, perform: handleDrop)
        .onChange(of: editor.agentService.focusInputRequestTick) { _, _ in
            Task { @MainActor in focused = true }
        }
        // A dialog card opened above: the composer is locked, so drop the mention popover and clear
        // any hover-drop highlight — no second input surface competes with the card.
        .onChange(of: blocked) { _, isBlocked in
            if isBlocked {
                mentionQuery = nil
                isDropTargeted = false
                showReferencePicker = false
            }
        }
        .alert("Couldn't attach media", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "The media couldn't be attached.")
        }
    }

    /// Invisible grab strip on the box's top edge: drag up to grow, down to shrink,
    /// clamped to the min/max. The resize cursor is the affordance.
    private var resizeHandle: some View {
        AppTheme.Background.clearColor
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
                .font(.system(size: AppTheme.FontSize.md))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.top, AppTheme.Spacing.smMd)
                .padding(.bottom, AppTheme.Spacing.xs)
                .focused($focused)
                .frame(height: clampedComposerHeight)
                .disabled(blocked)
                .opacity(blocked ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
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
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.top, AppTheme.Spacing.mdLg)
                    .allowsHitTesting(false)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
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
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.bold))
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
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.bold))
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(AppTheme.Accent.primary)
            .glassEffectID("sendStop", in: sendStopNamespace)
            .disabled(!canSend || blocked)
            .opacity(canSend && !blocked ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var attachButton: some View {
        Menu {
            Button {
                showReferencePicker = true
            } label: {
                Label(
                    pickableLibraryAssets.isEmpty
                        ? "Reference asset — No available assets"
                        : "Reference asset",
                    systemImage: "at"
                )
            }
            .disabled(pickableLibraryAssets.isEmpty)
            .help(pickableLibraryAssets.isEmpty ? "No available assets" : "Reference a library asset")

            Button(action: presentAttachPanel) {
                Label("Import new asset…", systemImage: "square.and.arrow.down")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .disabled(blocked)
        .opacity(blocked ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
        .help("Attach media")
        .popover(isPresented: $showReferencePicker, arrowEdge: .bottom) {
            LibraryAssetPicker(
                assets: pickableLibraryAssets,
                showsSearch: true,
                showsTypeTabs: true,
                scrollHeight: AppTheme.ComponentSize.agentAssetPickerHeight,
                pinnedId: editor.selectedMediaAssetIds.first,
                onPick: { asset in
                    editor.agentService.attachMention(for: asset)
                    showReferencePicker = false
                }
            )
            .frame(width: AppTheme.ComponentSize.agentAssetPickerWidth)
            .padding(AppTheme.Spacing.sm)
        }
    }

    private func presentAttachPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie, .image]
        panel.prompt = "Attach"
        panel.message = "Choose media to copy into the project. Originals stay in place."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            importAndMention(url)
        }
    }

    private func importAndMention(_ url: URL) {
        if let asset = editor.addMediaAsset(from: url) {
            editor.agentService.attachMention(for: asset)
        } else {
            attachmentError = editor.mediaPanelToast?.message ?? "The media couldn't be imported."
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
                } else if candidates.isEmpty {
                    // Nothing to pick — the file you're naming isn't in the library, so upload it.
                    uploadFromMention()
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

    /// Upload chosen from inside the @picker. Strip the half-typed `@query` first — unlike `pickMention`
    /// (which replaces it), the attach path only APPENDS its own token, so the fragment would otherwise
    /// linger as dead text. `presentAttachPanel` then imports the file and @mentions it, same as 📎.
    private func uploadFromMention() {
        if let lastAt = draft.lastIndex(of: "@") {
            draft = String(draft[..<lastAt])
        }
        mentionQuery = nil
        highlightedMentionIndex = 0
        presentAttachPanel()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !blocked else { return false }  // locked while a dialog card owns the input
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    importAndMention(url)
                }
            }
        }
        return handled
    }

    private func handlePaste(_: [NSItemProvider]) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            urls.forEach { importAndMention($0) }
            return
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            if let data = pb.data(forType: type) {
                if let asset = editor.importPastedImageData(data, fileExtension: ext) {
                    editor.agentService.attachMention(for: asset)
                } else {
                    attachmentError = editor.mediaPanelToast?.message ?? "The image couldn't be imported."
                }
                return
            }
        }
        // onPasteCommand swallows the default paste, so echo text manually.
        if let text = pb.string(forType: .string) { draft += text }
    }
}
