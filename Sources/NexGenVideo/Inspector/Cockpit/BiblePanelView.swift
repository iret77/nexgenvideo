import AppKit
import NexGenEngine
import SwiftUI

struct BiblePanelView: View {
    @Environment(\.projectPalette) private var palette
    @Environment(EditorViewModel.self) private var editor

    enum Section: String, CaseIterable, Hashable {
        case characters = "Characters"
        case ensembles = "Ensembles"
        case props = "Props"
        case locations = "Locations"
        case look = "Look"
        case references = "Shot references"
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
    @State private var spatialLocation: BibleEntityRef?
    @State private var panoramaLocation: BibleEntityRef?

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: editor.projectURL) { await load() }
        .onChange(of: editor.engineStateRevision) { _, _ in Task { await load() } }
        .onChange(of: editor.usesProductionPlanningV2) { _, enabled in
            if !enabled, section == .references { section = .characters }
        }
        .sheet(isPresented: Binding(get: { spatialLocation != nil }, set: { if !$0 { spatialLocation = nil } })) {
            if let spatialLocation, let home = editor.workingRoot {
                BibleSpatialViewSheet(home: home, locationID: spatialLocation.id).environment(editor)
            }
        }
        .sheet(isPresented: Binding(get: { panoramaLocation != nil }, set: { if !$0 { panoramaLocation = nil } })) {
            if let panoramaLocation, let home = editor.workingRoot {
                LocationPanoramaView(home: home, locationID: panoramaLocation.id).environment(editor)
            }
        }
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
                                   isStarting: editor.productionStarting, hasProduction: editor.hasProductionPipeline) { Task { await load() } }
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
        if section == .references {
            ProductionObligationView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    switch section {
                    case .characters: entityList(bible.characters, kind: .character)
                    case .ensembles: entityList(bible.ensembles, kind: .ensemble)
                    case .props: entityList(bible.props, kind: .prop)
                    case .locations: entityList(bible.locations, kind: .location)
                    case .look: lookContent(bible.look)
                    case .references: EmptyView()
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            ForEach(Section.allCases.filter { $0 != .references || editor.usesProductionPlanningV2 }, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .reviewAcceptanceProbe("bible.section", text: section.rawValue)
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
                BibleEntityCard(entity: entity, projectDir: editor.workingRoot, presentation: .board, reference: ref)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                            .strokeBorder(
                                isInspected ? palette.accent.opacity(AppTheme.Opacity.medium) : AppTheme.Background.clearColor,
                                lineWidth: AppTheme.BorderWidth.medium
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    .onTapGesture { inspect(ref) }
                    .accessibilityAction(named: "Inspect \(entity.name)") { inspect(ref) }
                if kind == .location, editor.usesProductionPlanningV2 {
                    Button("Panorama and camera views…") { panoramaLocation = ref }
                        .buttonStyle(InlineActionButtonStyle())
                        .disabled(editor.agentService.isStreaming || editor.agentService.isComposerBlocked)
                        .reviewAcceptanceProbe("bible.panorama.open.\(entity.id)")
                    Button("Create camera view…") { spatialLocation = ref }
                        .buttonStyle(InlineActionButtonStyle())
                        .disabled(editor.projectState?.nextPhaseName != "bible" || editor.agentService.isStreaming || editor.agentService.isComposerBlocked)
                        .help("Render a saved location camera, inspect its geometry view and assign it to this Bible location.")
                        .reviewAcceptanceProbe("bible.spatial.open.\(entity.id)")
                }
            }
        }
    }

    private func inspect(_ ref: BibleEntityRef) {
        editor.inspectedObject = .entity(ref)
        editor.inspectorPanelVisible = true
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
                            ? palette.accent.opacity(AppTheme.Opacity.medium)
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
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.ComponentSize.cockpitLabelWidth, alignment: .leading)
            Text(value)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - States

    private func emptyState(icon: String, title: String, message: String) -> some View {
        WorkspaceStateView(title: title, message: message, systemImage: icon) {}
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
    enum Presentation { case board, inspector }
    var presentation: Presentation = .inspector
    var reference: BibleEntityRef?
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header

            if presentation == .inspector, let ensemble = entity as? BibleEnsemble {
                membersRow(ensemble)
            }

            if presentation == .inspector, !entity.visualPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
                labeledBlock(label: "VISUAL PROMPT") {
                    Text(entity.visualPrompt)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if presentation == .inspector, !entity.attributes.isEmpty {
                labeledBlock(label: "ATTRIBUTES") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ForEach(entity.attributes) { attr in
                            attributeRow(key: attr.key, value: attr.value)
                        }
                    }
                }
            }

            if presentation == .board {
                if entity.sheets.isEmpty {
                    Text("No reference sheets")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                } else {
                    labeledBlock(label: "REFERENCE SHEETS") { sheetGrid(entity.sheets) }
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
                .interfaceFont(size: AppTheme.Typography.reading, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Text(entity.id)
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.medium, design: .monospaced)
                .foregroundStyle(AppTheme.Text.mutedColor)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func membersRow(_ ensemble: BibleEnsemble) -> some View {
        let count = ensemble.memberCount
        let desc = ensemble.membersDescription.trimmingCharacters(in: .whitespaces)
        if count != nil || !desc.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                if let count {
                    Text("\(count) members")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                if !desc.isEmpty {
                    Text(desc)
                        .interfaceFont(size: AppTheme.Typography.ui)
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
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.ComponentSize.cockpitLabelWidth, alignment: .leading)
            Text(value)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sheetGrid(_ sheets: [BibleSheet]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: AppTheme.ComponentSize.sheetTileMinWidth), spacing: AppTheme.Spacing.sm)],
            alignment: .leading,
            spacing: AppTheme.Spacing.sm
        ) {
            ForEach(sheets) { sheet in
                if let projectDir, let reference {
                    Button {
                        editor.openReferencePreview(ProjectReferenceImage(
                            projectHome: projectDir, path: sheet.path,
                            name: "\(entity.name.isEmpty ? entity.id : entity.name) — \(sheet.key)", entity: reference
                        ))
                    } label: {
                        SheetThumbnailView(label: sheet.key, path: sheet.path, projectDir: projectDir)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview \(entity.name), \(sheet.key)")
                } else {
                    SheetThumbnailView(label: sheet.key, path: sheet.path, projectDir: projectDir)
                }
            }
        }
    }

    private func labeledBlock<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label)
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sheet thumbnail

struct SheetThumbnailView: View {
    let label: String
    let path: String
    let projectDir: URL?
    var tileHeight: CGFloat = AppTheme.ComponentSize.sheetTileHeight

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ProjectReferenceImageView(projectHome: projectDir, path: path, compact: true)
                .frame(height: tileHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            Text(label)
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
        }
        .help(label)
    }
}
