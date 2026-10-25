import SwiftUI

struct TakeReviewNextShotView: View {
    let queue: TakeReviewQueue
    let shotID: String
    let enabled: Bool
    let open: (String) -> Void

    var body: some View {
        if queue.selectedShotIDs.contains(shotID) {
            if let next = queue.next(after: shotID) {
                if let takeID = next.takeID {
                    Button("Review next open shot · Shot \(next.number)") { open(takeID) }
                        .buttonStyle(InlineActionButtonStyle()).disabled(!enabled)
                        .reviewAcceptanceProbe("take.next", state: enabled, text: next.id)
                } else {
                    Text("Next open shot: Shot \(next.number). Render a video take before reviewing it.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .reviewAcceptanceProbe("take.next.missing", text: next.id)
                }
            } else {
                Text("All planned video shots have a selected take.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .reviewAcceptanceProbe("take.queue.complete")
            }
        }
    }
}
