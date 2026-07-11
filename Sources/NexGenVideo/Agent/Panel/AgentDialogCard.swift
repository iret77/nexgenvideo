import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The docked rendering of a pending `AgentDialog` (locked placement architecture, #96): a native
/// card that shapes a step with clicks instead of prose. Presenter-agnostic — the agent panel hosts
/// it to compose a chat message, the generation panels host it to compile a prompt — so it takes an
/// `onSubmit`/`onCancel` pair and owns its own dialog-scoped free-text field. Never a modal, never a
/// transcript card.
struct AgentDialogCard: View {
    let dialog: AgentDialog
    /// Seeds a section's initial selection (e.g. a mood chosen from a menu before the dialog opens).
    var preselected: [String: Set<String>] = [:]
    /// When bound (agent panel with canvas projection, #124), choice selection lives OUTSIDE the card
    /// so a click on a projected timeline range and a chip tap stay in sync. Nil ⇒ the card owns its
    /// own selection (Music-tab and any non-projected use — unchanged behavior).
    var externalSelections: Binding<[String: Set<String>]>? = nil
    /// The active pack's brand accent, used to make a `fileIntake` well recognizably the pack's own
    /// (the upload step everything downstream depends on). Defaults to the host accent.
    var accent: Color = AppTheme.Accent.primary
    let onSubmit: (AgentDialogResult) -> Void
    let onCancel: () -> Void

    @State private var localChoiceSelections: [String: Set<String>] = [:]
    @State private var toggleStates: [String: Bool] = [:]
    @State private var direction: String = ""
    /// Per-section "Other…" free text, for choice sections with `allowsCustom`.
    @State private var customText: [String: String] = [:]
    @State private var isDropTargeted = false
    /// Files chosen for a `fileIntake` dialog — via the drop zone or the native picker.
    @State private var pickedFiles: [URL] = []

    private var choiceSelections: [String: Set<String>] {
        get { externalSelections?.wrappedValue ?? localChoiceSelections }
        nonmutating set {
            if let externalSelections { externalSelections.wrappedValue = newValue }
            else { localChoiceSelections = newValue }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            if let intro = dialog.intro {
                Text(intro)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(dialog.sections) { section in
                sectionView(section)
            }
            if let tf = dialog.textField {
                dialogField(tf.placeholder, text: $direction, lineLimit: tf.multiline ? 3...12 : 1...3)
            }
            if let intake = dialog.fileIntake {
                fileWell(intake)
            }
            footerRow
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(isDropTargeted ? accent : accent.opacity(AppTheme.Opacity.medium),
                              lineWidth: isDropTargeted ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin)
        )
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        // A file-intake dialog accepts a drop anywhere on the card (a big, forgiving target) — a leaf
        // drop, not shadowed by any parent .onDrop. Non-file dialogs take no drop (isTargeted nil).
        .onDrop(of: [.fileURL],
                isTargeted: dialog.fileIntake != nil ? $isDropTargeted : nil,
                perform: handleFileDrop)
        .onAppear(perform: seedDefaults)
        .id(dialog.id)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let intake = dialog.fileIntake else { return false }
        let loaders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !loaders.isEmpty else { return false }
        for provider in loaders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    guard accepts(url, intake) else { return }
                    addPicked(url, intake)
                }
            }
        }
        return true
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: dialog.symbol)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(accent)
            Text(dialog.title)
                .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Dismiss (Esc)")
        }
    }

    @ViewBuilder
    private func sectionView(_ section: AgentDialog.Section) -> some View {
        switch section.kind {
        case .choices(let options, let multiSelect):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(section.label.uppercased())
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                FlowChips(options: options,
                          selected: choiceSelections[section.id] ?? [],
                          multiSelect: multiSelect,
                          accent: accent) { optionId in
                    toggleChoice(sectionId: section.id, optionId: optionId, multiSelect: multiSelect)
                }
                if section.allowsCustom {
                    dialogField("Other…", text: Binding(
                        get: { customText[section.id] ?? "" },
                        set: { customText[section.id] = $0 }
                    ))
                }
            }
        case .toggle:
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(section.label)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { toggleStates[section.id] ?? false },
                    set: { toggleStates[section.id] = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
    }

    /// The single text-input styling for a dialog card — reused by the free-text field, per-section
    /// "Other…" inputs, and the file-intake identity name, so every input field in the AI chat looks
    /// and behaves identically (one design, no one-offs).
    private func dialogField(_ placeholder: String, text: Binding<String>, lineLimit: ClosedRange<Int> = 1...3) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(lineLimit)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .padding(AppTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.black.opacity(AppTheme.Opacity.muted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
    }

    // MARK: - File intake

    @ViewBuilder
    private func fileWell(_ intake: AgentDialog.FileIntake) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if let namePrompt = intake.namePrompt {
                dialogField(namePrompt, text: $direction)
            }
            if pickedFiles.isEmpty {
                emptyFileWell(intake)
            } else {
                ForEach(pickedFiles, id: \.self) { pickedFileChip($0) }
                if intake.allowsMultiple {
                    chooseButton(intake, label: "Add another…")
                }
            }
        }
    }

    /// Prominent, accent-tinted drop zone. Everything downstream in a pack workflow hangs on this one
    /// upload (the song / lyrics), so it reads as the card's primary action — the pack's accent color,
    /// a large glyph, a clear call to action, and a filled Choose button — not a quiet inline field.
    private func emptyFileWell(_ intake: AgentDialog.FileIntake) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: AppTheme.FontSize.xl))
                .foregroundStyle(accent)
            Text(intake.prompt ?? "Drop a file here or choose one")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { presentFilePanel(intake) } label: {
                Text("Choose…").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .controlSize(.regular)
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(accent.opacity(isDropTargeted ? AppTheme.Opacity.muted : AppTheme.Opacity.faint))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(accent.opacity(isDropTargeted ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong),
                              style: StrokeStyle(lineWidth: isDropTargeted ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin,
                                                 dash: [AppTheme.Spacing.xs]))
        )
        .animation(.easeInOut(duration: AppTheme.Anim.hover), value: isDropTargeted)
    }

    private func pickedFileChip(_ url: URL) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: fileSymbol(url))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(accent)
            Text(url.lastPathComponent)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button {
                pickedFiles.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.black.opacity(AppTheme.Opacity.muted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private func chooseButton(_ intake: AgentDialog.FileIntake, label: String) -> some View {
        Button(label) { presentFilePanel(intake) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func presentFilePanel(_ intake: AgentDialog.FileIntake) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = intake.allowsMultiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let types = allowedContentTypes(intake)
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = "Choose"
        if let prompt = intake.prompt { panel.message = prompt }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where accepts(url, intake) {
            addPicked(url, intake)
        }
    }

    private func addPicked(_ url: URL, _ intake: AgentDialog.FileIntake) {
        if intake.allowsMultiple {
            if !pickedFiles.contains(url) { pickedFiles.append(url) }
        } else {
            pickedFiles = [url]
        }
    }

    private func allowedContentTypes(_ intake: AgentDialog.FileIntake) -> [UTType] {
        var types: [UTType] = []
        for token in intake.accept {
            switch token.lowercased() {
            case "audio": types.append(.audio)
            case "video", "movie": types.append(.movie)
            case "image": types.append(.image)
            case "text": types.append(contentsOf: [.plainText, .text])
            default:
                if let type = UTType(filenameExtension: token) { types.append(type) }
            }
        }
        return types
    }

    private func accepts(_ url: URL, _ intake: AgentDialog.FileIntake) -> Bool {
        let allowed = allowedContentTypes(intake)
        guard !allowed.isEmpty else { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return allowed.contains { type.conforms(to: $0) }
    }

    private func fileSymbol(_ url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .text) { return "doc.plaintext" }
        return "doc"
    }

    private var footerRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let cost = dialog.costHint {
                Text(cost)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            Spacer()
            Button(dialog.confirmLabel) { submit() }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.small)
                .disabled(!canSubmit)
        }
    }

    /// When the dialog can be confirmed. No file intake ⇒ always (choices/text). With a file intake:
    /// if it also has a textField (paste-OR-upload, e.g. lyrics) a file OR non-empty text suffices;
    /// otherwise a file is required, plus the identity name when the intake asks for one.
    private var canSubmit: Bool {
        guard let intake = dialog.fileIntake else { return true }
        if !intake.required { return true }  // optional intake: confirm even with nothing (an explicit skip)
        let hasText = !direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if dialog.textField != nil { return !pickedFiles.isEmpty || hasText }
        if pickedFiles.isEmpty { return false }
        if intake.namePrompt != nil, !hasText { return false }
        return true
    }

    // MARK: - State

    private func seedDefaults() {
        for section in dialog.sections {
            if case .toggle(let defaultOn) = section.kind, toggleStates[section.id] == nil {
                toggleStates[section.id] = defaultOn
            }
        }
        for (sectionId, selection) in preselected where choiceSelections[sectionId] == nil {
            choiceSelections[sectionId] = selection
        }
    }

    private func toggleChoice(sectionId: String, optionId: String, multiSelect: Bool) {
        var current = choiceSelections[sectionId] ?? []
        if multiSelect {
            if current.contains(optionId) { current.remove(optionId) } else { current.insert(optionId) }
        } else {
            current = current.contains(optionId) ? [] : [optionId]
        }
        choiceSelections[sectionId] = current
    }

    private func submit() {
        var selectedLabels: [String: [String]] = [:]
        for section in dialog.sections {
            if case .choices(let options, _) = section.kind {
                let picked = options.filter { (choiceSelections[section.id] ?? []).contains($0.id) }
                if !picked.isEmpty { selectedLabels[section.id] = picked.map(\.label) }
            }
        }
        let customs = customText
            .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        onSubmit(AgentDialogResult(
            selectedLabels: selectedLabels,
            toggles: toggleStates,
            direction: direction.trimmingCharacters(in: .whitespacesAndNewlines),
            customValues: customs,
            fileURLs: pickedFiles
        ))
    }
}

/// Wrapping chip rows for choice options — compact controls only; rich visual picking belongs to
/// the canonical surfaces (canvas projection), not this card.
private struct FlowChips: View {
    let options: [AgentDialog.Choice]
    let selected: Set<String>
    let multiSelect: Bool
    var accent: Color = AppTheme.Accent.primary
    let onTap: (String) -> Void

    var body: some View {
        // Wrap at each chip's NATURAL width — a fixed-column grid + lineLimit(1) truncated longer
        // labels ("Local file on this Mac", "I'll drag it in / point to it").
        WrapLayout(spacing: AppTheme.Spacing.xs) {
            ForEach(options) { option in
                let isOn = selected.contains(option.id)
                Button {
                    onTap(option.id)
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: AppTheme.FontSize.xxs))
                        }
                        Text(option.label)
                            .font(.system(size: AppTheme.FontSize.xs,
                                          weight: isOn ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .foregroundStyle(isOn ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    .background(
                        Capsule().fill(isOn
                                       ? accent.opacity(AppTheme.Opacity.faint)
                                       : Color.white.opacity(AppTheme.Opacity.subtle))
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isOn ? accent : AppTheme.Border.subtleColor,
                            lineWidth: AppTheme.BorderWidth.hairline)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
