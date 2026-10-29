import Foundation
import NexGenEngine

enum PipelineMusicvideoPromptContextV2 {
    static func current(projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> MusicvideoProductionExtensionV2? {
        guard projection.executionPlan.extensionReferences.contains(where: { $0.id == MusicvideoProductionExtensionV2.artifactID }) else { return nil }
        return try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
    }

    static func visual(music: MusicvideoProductionExtensionV2, shotID: String, still: Bool) -> [String] {
        let arc = PipelineMusicvideoProductionWriter.visualArcDirectives(visualArc: music.visualArc, shotID: shotID)
        guard still else { return arc + PipelineMusicvideoProductionWriter.coverageDirectives(coverage: music.coverage, shotID: shotID) }
        let coverage = music.coverage.flatMap { item in
            item.evidence.filter { $0.shotIDs.contains(shotID) && !item.approvedExceptionRoleIDs.contains($0.roleID) }.map { evidence in
                var visible: [String] = []
                if evidence.showsFullBody { visible.append("the full body") }
                if evidence.showsFloorContact { visible.append("floor contact") }
                if evidence.showsHandsAndOrientation { visible.append("hands and orientation") }
                if let instrument = evidence.instrumentID { visible.append("instrument " + instrument) }
                return "Approved performance reference for role \(evidence.roleID): preserve \(visible.joined(separator: ", ")) in this boundary still. It does not prove continuous performance or musical synchronization."
            }
        }
        return arc + coverage
    }

    static func performance(music: MusicvideoProductionExtensionV2, shotID: String, audioLabel: String?) throws -> [String] {
        guard let segment = music.performanceSegments.first(where: { $0.draft.shotIDs.contains(shotID) })?.draft else { return [] }
        guard let audioLabel, !audioLabel.isEmpty else {
            throw GateBlocked("The exact approved original-song phrase is missing from this performance shot's compiled inputs.")
        }
        var result = ["\(audioLabel) is the exact approved original-song phrase. Use it only for \(segment.purpose.rawValue.replacingOccurrences(of: "_", with: " ")). Do not generate replacement music or an additional song bed."]
        if segment.purpose == .performedSong {
            for owner in segment.mouthOwnership {
                let start = owner.timelineStartSeconds - segment.timelineStartSeconds
                let end = owner.timelineEndSeconds - segment.timelineStartSeconds
                result.append("Within the supplied phrase, from \(seconds(start))s to \(seconds(end))s only performer \(owner.performerID) mouths voice \(owner.voiceID). These times use the phrase's own clock, not the project timeline.")
            }
            let owners = Set(segment.mouthOwnership.map(\.performerID))
            let silent = segment.performerIDs.filter { !owners.contains($0) }
            if !silent.isEmpty { result.append("These visible performers do not sing in this phrase: " + silent.joined(separator: ", ") + ".") }
        }
        return result
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) }
}
