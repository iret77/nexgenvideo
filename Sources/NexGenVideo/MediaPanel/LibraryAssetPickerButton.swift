import SwiftUI

struct LibraryAssetPickerButton: View {
    @Environment(EditorViewModel.self) private var editor
    let purpose: MediaPickerPurpose
    let acceptedTypes: Set<ClipType>
    var title = "Choose from Library…"
    var excludedIDs: Set<String> = []
    let onPick: (MediaAsset) -> Void
    @State private var isPresented = false

    var body: some View {
        Button(title, systemImage: "photo.on.rectangle") { isPresented = true }
            .buttonStyle(.inlineAction())
            .popover(isPresented: $isPresented) {
                LibraryAssetPicker(
                    assets: editor.agentPickableMediaAssets.filter {
                        acceptedTypes.contains($0.type) && !excludedIDs.contains($0.id)
                    },
                    showsSearch: true,
                    showsTypeTabs: acceptedTypes.count > 1,
                    scrollHeight: AppTheme.ComponentSize.agentAssetPickerHeight,
                    state: editor.mediaPickerState(for: purpose),
                    onReveal: { asset in
                        isPresented = false
                        editor.revealAssetInMedia(asset)
                    }
                ) { asset in
                    onPick(asset)
                    isPresented = false
                }
                .frame(width: AppTheme.ComponentSize.agentAssetPickerWidth)
                .padding(AppTheme.Spacing.sm)
            }
    }
}

extension EditorViewModel {
    func revealAssetInMedia(_ asset: MediaAsset) {
        guard mediaAssets.contains(where: { $0.id == asset.id }) else { return }
        setWorkspaceFocus(.media)
        setMediaPanelTab(.assets, for: .media)
        maximizedPanel = nil
        theaterActive = false
        selectMediaAsset(asset)
        focusedPanel = .media
        mediaPanelRevealAssetId = asset.id
    }
}
