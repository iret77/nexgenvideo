import SwiftUI

struct MediaWorkspaceCenterView: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            if let progress = editor.mediaImportProgress {
                MediaImportProgressBanner(progress: progress)
            }
            VSplitView {
                MediaTab(workspace: .media)
                    .frame(minHeight: AppTheme.Layout.mediaBrowserMinHeight)
                    .accessibilityIdentifier("media.workspace.browser")
                    .background {
                        if WorkspaceUIAcceptance.isRequested {
                            AppRelaunchClickProbe(identifier: "media.workspace.browser")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        editor.focusedPanel = .preview
                        editor.mediaCommandFocus = .browser
                    })
                PreviewContainerView()
                    .frame(minHeight: AppTheme.Layout.previewMinHeight)
                    .accessibilityIdentifier("media.workspace.sourcePreview")
                    .background {
                        if WorkspaceUIAcceptance.isRequested {
                            AppRelaunchClickProbe(identifier: "media.workspace.sourcePreview")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        editor.focusedPanel = .preview
                        editor.mediaCommandFocus = .sourcePreview
                    })
            }
        }
    }
}

struct CompactMediaSourcePicker: View {
    @Environment(EditorViewModel.self) private var editor
    let purpose: MediaLibraryPurpose
    let title: String

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(title)
                    .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: AppTheme.Spacing.sm)
                Button {
                    MediaImportFlow.present(
                        editor: editor,
                        destinationFolderId: editor.mediaLibrarySession(for: purpose).folderID
                    )
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .buttonStyle(.capsule(.secondary))
                .help("Copy media into the project")
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .frame(height: AppTheme.Layout.workspaceHeaderHeight)
            .panelHeaderBar()

            LibraryAssetPicker(
                assets: editor.mediaAssets.filter { !$0.isGenerating },
                purpose: purpose,
                showsSearch: true,
                showsTypeTabs: true,
                scrollHeight: AppTheme.ComponentSize.agentAssetPickerHeight,
                allowsDragging: true,
                emptyLabel: "No available media"
            ) { asset in
                editor.selectMediaAsset(asset, for: purpose)
            }
            .padding(AppTheme.Spacing.sm)

            HStack(spacing: AppTheme.Spacing.sm) {
                Spacer(minLength: AppTheme.Spacing.none)
                Button("Show in Media") {
                    guard let id = editor.mediaLibrarySession(for: purpose).activeAssetID else { return }
                    editor.revealMediaAsset(id: id)
                }
                .buttonStyle(.capsule(.secondary))
                .disabled(editor.mediaLibrarySession(for: purpose).activeAssetID == nil)
                .background {
                    if WorkspaceUIAcceptance.isRequested {
                        AppRelaunchClickProbe(
                            identifier: "mediaPicker.\(purpose.accessibilitySuffix).showInMedia"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    }
                }
            }
            .padding(AppTheme.Spacing.sm)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AppTheme.Border.primaryColor)
                    .frame(height: AppTheme.BorderWidth.hairline)
            }
        }
        .frame(minHeight: AppTheme.Layout.compactMediaPickerMinHeight)
        .background(AppTheme.Background.surfaceColor)
    }
}

struct ProductionWorkspaceSidebar: View {
    @State private var showsLibrary = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            AgentPanelView()
            compactLibraryDisclosure(
                title: "Production Sources",
                purpose: .productionSource,
                showsLibrary: $showsLibrary
            )
        }
    }
}

struct PostproductionWorkspaceSidebar: View {
    @State private var showsLibrary = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            FinishReviewPane()
            compactLibraryDisclosure(
                title: "Postproduction Sources",
                purpose: .postproductionSource,
                showsLibrary: $showsLibrary
            )
        }
    }
}

private func compactLibraryDisclosure(
    title: String,
    purpose: MediaLibraryPurpose,
    showsLibrary: Binding<Bool>
) -> some View {
    VStack(spacing: AppTheme.Spacing.none) {
        Button {
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                showsLibrary.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: showsLibrary.wrappedValue ? "chevron.down" : "chevron.right")
                Text("Library")
                Spacer(minLength: AppTheme.Spacing.sm)
                Image(systemName: "photo.on.rectangle.angled")
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .frame(height: AppTheme.Layout.workspaceHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .accessibilityLabel(showsLibrary.wrappedValue ? "Hide Library" : "Show Library")
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(
                    identifier: "mediaPicker.toggle.\(purpose.accessibilitySuffix)",
                    acceptanceState: showsLibrary.wrappedValue
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }

        if showsLibrary.wrappedValue {
            CompactMediaSourcePicker(purpose: purpose, title: title)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    .overlay(alignment: .top) {
        Rectangle()
            .fill(AppTheme.Border.primaryColor)
            .frame(height: AppTheme.BorderWidth.hairline)
    }
}
