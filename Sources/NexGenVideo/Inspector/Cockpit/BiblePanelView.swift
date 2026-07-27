import AppKit
import SwiftUI

// Read-only Bible cockpit panel: shows the production Bible (characters, ensembles, props, locations,
// look) with reference-sheet thumbnails, loaded via the engine read CLI (CockpitDataService.bible).
// Segmented picker across the entity kinds; per-entity cards; explicit loading / empty / error /
// engine-not-ready states. No mutations.

struct BiblePanelView: View {
    @Environment(EditorViewModel.self) private var editor

    enum Section: String, CaseIterable, Hashable {
        case characters = "Characters"
        case ensembles = "Ensembles"
        case props = "Props"
        case locations = "Locations"
        case look = "Look"
    }

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded(BibleData?)
        case failed(CockpitError)
    }

    @State private var state: LoadState = .idle
    @State private var section: Section = .characters
    /// Guards against a stale reload result overwriting a newer one when the project changes mid-flight.
    @State private var loadToken = 0

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: editor.projectURL) { await load() }
        .onChange(of: editor.engineStateRevision) { _, _ in Task { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            centered { ProgressView().controlSize(.small) }
        case .failed(let error):
            CockpitStateView.error(error, title: "Couldn't load the Bible",
                                   subject: "the Bible",
                                   activePack: InstalledPack.named(editor.activePluginName),
                                   startProduction: { editor.startProduction() },
                                   isStarting: editor.productionStarted) { Task { await load() } }
        case .loaded(nil):
            emptyState(
                icon: "book.closed",
                title: "No Bible yet",
                message: "This project doesn't have a production Bible."
            )
        case .loaded(.some(let bible)):
            loadedBody(bible)
        }
    }

    @ViewBuilder
    private func loadedBody(_ bible: BibleData) -> some View {
        sectionPicker
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                switch section {
                case .characters: entityList(bible.characters, kind: .character)
                case .ensembles: entityList(bible.ensembles, kind: .ensemble)
                case .props: entityList(bible.props, kind: .prop)
                case .locations: entityList(bible.locations, kind: .location)
                case .look: lookContent(bible.look)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.top, AppTheme.Spacing.md)
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    // MARK: - Entity list

    @ViewBuilder
    private func entityList<Entity: BibleEntity & Identifiable>(_ entities: [Entity], kind: BibleEntityKind) -> some View {
        if entities.isEmpty {
            emptyState(
                icon: "tray",
                title: "None yet",
                message: "No \(section.rawValue.lowercased()) in this Bible."
            )
        } else {
            ForEach(entities) { entity in
                let ref = BibleEntityRef(kind: kind, id: entity.id)
                let isInspected = editor.inspectedObject == .entity(ref)
                BibleEntityCard(entity: entity, projectDir: editor.workingRoot)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                            .strokeBorder(
                                isInspected ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium) : AppTheme.Background.clearColor,
                                lineWidth: AppTheme.BorderWidth.medium
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    .onTapGesture { editor.inspectedObject = .entity(ref) }
            }
        }
    }

    // MARK: - Look

    @ViewBuilder
    private func lookContent(_ look: BibleLook) -> some View {
        if look.isEmpty {
            emptyState(
                icon: "paintpalette",
                title: "No look defined",
                message: "This Bible has no look guide yet."
            )
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                ForEach(look.fields, id: \.label) { field in
                    keyValueRow(key: field.label, value: field.value)
                }
            }
            .padding(AppTheme.Spacing.mdLg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(AppTheme.Background.raisedColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(
                        editor.inspectedObject == .look
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium)
                            : AppTheme.Border.subtleColor,
                        lineWidth: editor.inspectedObject == .look ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .onTapGesture { editor.inspectedObject = .look }
        }
    }

    private func keyValueRow(key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Text(key)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.ComponentSize.cockpitLabelWidth, alignment: .leading)
            Text(value)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - States

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.title1))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(title)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text(message)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load

    private func load() async {
        guard let dir = editor.workingRoot else {
            state = .failed(.noProject)
            return
        }
        loadToken += 1
        let token = loadToken
        state = .loading
        let result = await CockpitDataService.bible(projectDir: dir)
        guard token == loadToken else { return }
        switch result {
        case .success(let bible): state = .loaded(bible)
        case .failure(let error): state = .failed(error)
        }
    }
}

// MARK: - Entity card

struct BibleEntityCard: View {
    let entity: any BibleEntity
    let projectDir: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header

            if !entity.hardRecognitionTrait.trimmingCharacters(in: .whitespaces).isEmpty {
                traitRow(entity.hardRecognitionTrait)
            }

            if let ensemble = entity as? BibleEnsemble {
                membersRow(ensemble)
            }

            if !entity.visualPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
                labeledBlock(label: "VISUAL PROMPT") {
                    Text(entity.visualPrompt)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !entity.attributes.isEmpty {
                labeledBlock(label: "ATTRIBUTES") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ForEach(entity.attributes) { attr in
                            attributeRow(key: attr.key, value: attr.value)
                        }
                    }
                }
            }

            if !entity.sheets.isEmpty {
                labeledBlock(label: "REFERENCE SHEETS") {
                    sheetGrid(entity.sheets)
                }
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text(entity.name.isEmpty ? entity.id : entity.name)
                .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Text(entity.id)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium).monospaced())
                .foregroundStyle(AppTheme.Text.mutedColor)
                .lineLimit(1)
        }
    }

    private func traitRow(_ trait: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
            Image(systemName: "target")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Accent.timecodeColor)
                .padding(.top, AppTheme.Spacing.xxs)
            Text(trait)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Accent.timecodeColor.opacity(AppTheme.Opacity.faint))
        )
    }

    @ViewBuilder
    private func membersRow(_ ensemble: BibleEnsemble) -> some View {
        let count = ensemble.memberCount
        let desc = ensemble.membersDescription.trimmingCharacters(in: .whitespaces)
        if count != nil || !desc.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                if let count {
                    Text("\(count) members")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                if !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func attributeRow(key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Text(key)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.ComponentSize.cockpitLabelWidth, alignment: .leading)
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sheetGrid(_ sheets: [BibleSheet]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 88), spacing: AppTheme.Spacing.sm)],
            alignment: .leading,
            spacing: AppTheme.Spacing.sm
        ) {
            ForEach(sheets) { sheet in
                SheetThumbnailView(label: sheet.key, path: sheet.path, projectDir: projectDir)
            }
        }
    }

    private func labeledBlock<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sheet thumbnail

/// A single reference-sheet tile. Resolves `projectDir + relative path`, loads it with
/// `NSImage(contentsOfFile:)` off the main actor, and falls back to a placeholder when missing.
struct SheetThumbnailView: View {
    let label: String
    let path: String
    let projectDir: URL?
    var tileHeight: CGFloat = 64

    @State private var image: NSImage?
    @State private var didAttempt = false

    private var resolvedURL: URL? {
        guard let projectDir, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, relativeTo: projectDir).standardizedFileURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack {
                Rectangle().fill(AppTheme.Background.overlayColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: didAttempt ? "photo" : "photo.on.rectangle")
                        .font(.system(size: AppTheme.FontSize.mdLg))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            .frame(height: tileHeight)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.hairline)
            )
            Text(label)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .lineLimit(1)
        }
        .help(resolvedURL.map { "\(label) · \($0.path)" } ?? label)
        .task(id: resolvedURL) { await loadImage() }
    }

    private func loadImage() async {
        guard let url = resolvedURL else {
            image = nil
            didAttempt = true
            return
        }
        // Read bytes off the main actor (Data is Sendable); build the NSImage on the main actor —
        // the codebase keeps non-Sendable AppKit image types off background boundaries.
        let bytes = await Task.detached(priority: .utility) { () -> Data? in
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        image = bytes.flatMap { NSImage(data: $0) }
        didAttempt = true
    }
}
