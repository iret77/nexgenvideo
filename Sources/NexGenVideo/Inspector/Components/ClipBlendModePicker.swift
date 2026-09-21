import SwiftUI

struct ClipBlendModePicker: View {
    @Environment(EditorViewModel.self) private var editor
    let clips: [Clip]

    private var selection: String {
        guard let first = clips.first,
              clips.allSatisfy({ $0.blendMode == first.blendMode && ($0.compositing == nil || $0.compositing?.supportedMode != nil) })
        else { return "" }
        return first.blendMode.rawValue
    }

    var body: some View {
        let titles = Set(clips.map(\.blendModeTitle))
        let placeholder = titles.count == 1 ? titles.first! : "Mixed"
        let modes = ClipBlendMode.allCases.map { NativeChoicePicker.Option(id: $0.rawValue, title: $0.title) }
        NativeChoicePicker(
            label: "Blend Mode",
            options: selection.isEmpty ? [.init(id: "", title: placeholder, isEnabled: false)] + modes : modes,
            selection: Binding(get: { selection }, set: { raw in
                guard let mode = ClipBlendMode(rawValue: raw) else { return }
                do { try editor.setClipBlendMode(mode, clipIds: clips.map(\.id)) }
                catch { Log.preview.error("Blend mode change failed: \(error.localizedDescription)") }
            })
        )
        .disabled(clips.isEmpty || clips.contains { !$0.mediaType.isVisual })
        .help("Blend selected visual clips with the layers below them")
    }
}
