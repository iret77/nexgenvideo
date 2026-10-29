import Foundation
import NexGenEngine

enum PipelineProductionMusicCoverage {
    struct Binding: Codable, Sendable, Equatable {
        let coverageID: String
        let roleID: String
        let assemblyRoleID: String
        let clipIDs: [String]
        let takeIDs: [String]
        let sourceReferences: [CanonicalArtifactReferenceV1]
        let longestContinuousTicks: Int64
    }

    static func bindings(projection: ProductionPlanProjectionV1, proof: ProductionPlanAssemblyProofV1,
                         dataRoot: URL) throws -> [Binding] {
        let music = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
        return try music.coverage.flatMap { coverage in
            try coverage.evidence.filter { !coverage.approvedExceptionRoleIDs.contains($0.roleID) }.map { evidence in
                let placements = evidence.shotIDs.map { id in proof.placements.filter { $0.shotID == id } }.flatMap { $0 }
                guard placements.map(\.shotID) == evidence.shotIDs else { throw changed() }
                try requireVideo(placements)
                let longest = try longestContinuous(placements)
                guard proof.timebase.seconds(for: longest) >= evidence.minimumContinuousSeconds else { throw changed() }
                return Binding(coverageID: coverage.id, roleID: evidence.roleID, assemblyRoleID: evidence.assemblyRoleID,
                    clipIDs: placements.map(\.clipID), takeIDs: placements.compactMap(\.takeID),
                    sourceReferences: placements.flatMap { [$0.output] + [$0.selectionReceipt, $0.nativeRange].compactMap { $0 } },
                    longestContinuousTicks: longest)
            }
        }
    }

    static func requireVideo(_ placements: [ProductionPlanAssemblyProofV1.Placement]) throws {
        guard !placements.isEmpty, placements.allSatisfy({ $0.sourceKind == .video }) else { throw changed() }
    }

    static func longestContinuous(_ placements: [ProductionPlanAssemblyProofV1.Placement]) throws -> Int64 {
        var first: Int64?, end: Int64 = 0, longest: Int64 = 0
        for placement in placements.sorted(by: { $0.startTicks < $1.startTicks }) {
            let next = placement.startTicks.addingReportingOverflow(placement.durationTicks)
            guard !next.overflow, placement.startTicks >= 0, placement.durationTicks > 0 else { throw changed() }
            if let first, placement.startTicks <= end { end = max(end, next.partialValue); longest = max(longest, end - first) }
            else { first = placement.startTicks; end = next.partialValue; longest = max(longest, placement.durationTicks) }
        }
        return longest
    }

    private static func changed() -> GateBlocked {
        GateBlocked("The selected clips do not provide the declared continuous Music Video coverage. Restore the required actual shot and take intervals before assembly.")
    }
}
