import SwiftUI

/// Left-sidebar panel hosting the Assets library, Captions, and Music tabs. Its second-level
/// navigation uses the canonical horizontal `SegmentedTabBar` — the same idiom as the Project cockpit —
/// so the sidebar speaks one consistent sub-navigation language (docs/UI_UX_CONCEPT.md §2.1). Tab state
/// lives on the view model, so switching sidebar tabs never loses the sub-tab.
struct MediaPanelView: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        @Bindable var editor = editor
        VStack(spacing: AppTheme.Spacing.none) {
            SegmentedTabBar(
                titles: EditorViewModel.MediaPanelTab.allCases.map(\.rawValue),
                selected: editor.mediaPanelTab.rawValue
            ) { title in
                if let tab = EditorViewModel.MediaPanelTab(rawValue: title) {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) { editor.mediaPanelTab = tab }
                }
            }
            Group {
                switch editor.mediaPanelTab {
                case .assets: MediaTab()
                case .captions: CaptionTab()
                case .music: MusicTab()
                }
            }
            .frame(minWidth: AppTheme.Spacing.none, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
    }
}
