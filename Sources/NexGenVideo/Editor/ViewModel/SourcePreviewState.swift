import Foundation

struct SourcePreviewState: Equatable {
    var positionSeconds: Double = 0
    var inSeconds: Double?
    var outSeconds: Double?
    var targetTrackID: String?
}
