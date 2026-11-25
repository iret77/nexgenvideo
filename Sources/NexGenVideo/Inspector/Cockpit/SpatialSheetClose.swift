import Foundation

@MainActor
enum SpatialSheetClose {
    // Closing must stop background reads directly; SwiftUI may tear the sheet down much later.
    static func close(render: Task<Void, Never>?, reads: BpyOperationCancellation, dismiss: () -> Void) {
        render?.cancel()
        reads.cancel()
        dismiss()
    }
}
