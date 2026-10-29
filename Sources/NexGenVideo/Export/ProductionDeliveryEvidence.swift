import CoreMedia
import Foundation
import NexGenEngine

struct ProductionDeliveryRangeExpectation: Codable, Sendable, Equatable {
    let schema: String
    let attemptID: String
    let timelineSHA256: String
    let productionFingerprint: String
    let startValue: Int64
    let startTimescale: Int32
    let durationValue: Int64
    let durationTimescale: Int32

    init(snapshot: ProductionExportBinding.Snapshot, attempt: DeliveryAttemptV1) throws {
        guard snapshot.range.start.isNumeric, snapshot.range.duration.isNumeric,
              snapshot.range.start.timescale > 0, snapshot.range.duration.timescale > 0,
              CMTimeCompare(snapshot.range.start, .zero) >= 0, CMTimeCompare(snapshot.range.duration, .zero) > 0 else { throw Self.invalid() }
        schema = "production-delivery-range/v1"
        attemptID = attempt.id
        timelineSHA256 = attempt.finishedTimelineSHA256
        productionFingerprint = snapshot.fingerprint
        startValue = snapshot.range.start.value
        startTimescale = snapshot.range.start.timescale
        durationValue = snapshot.range.duration.value
        durationTimescale = snapshot.range.duration.timescale
        try validate(attempt: attempt)
    }

    var range: CMTimeRange {
        CMTimeRange(start: CMTime(value: startValue, timescale: startTimescale),
            duration: CMTime(value: durationValue, timescale: durationTimescale))
    }
    static func path(attemptID: String) -> String { "delivery/jobs/\(attemptID)/production-range.v1.json" }

    func validate(attempt: DeliveryAttemptV1) throws {
        guard schema == "production-delivery-range/v1", attemptID == attempt.id,
              timelineSHA256 == attempt.finishedTimelineSHA256, productionFingerprint.count == 64,
              productionFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              startTimescale > 0, durationTimescale > 0, startValue >= 0, durationValue > 0, range.end.isNumeric else { throw Self.invalid() }
    }
    private static func invalid() -> GateBlocked { GateBlocked("The delivery has no valid bound production output interval.") }
}

struct ProductionFinishedEvidence: Codable, Sendable, Equatable {
    static let currentPath = "delivery/production-finished-current.v1.json"
    let schema: String
    let projectID: String
    let timelineSHA256: String
    let finishPlanSHA256: String
    let finishedManifestSHA256: String
    let productionFingerprint: String
    let review: CanonicalArtifactReferenceV1
    static func archivePath(bytes: Data) -> String {
        "delivery/production-finishes/" + FileDigest.sha256(of: bytes) + ".v1.json"
    }
}
