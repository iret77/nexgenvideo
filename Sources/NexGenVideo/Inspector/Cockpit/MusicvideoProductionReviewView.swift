import Foundation
import NexGenEngine
import SwiftUI

struct MusicvideoProductionReviewView: View {
    let snapshot: ProductionPlanPresentation.Snapshot
    let dataRoot: URL
    @State private var details: Details?
    @State private var failure: String?
    @State private var generation = UUID()

    private struct LoadKey: Equatable {
        let root: URL
        let projection: ProductionPlanProjectionV1
    }

    private struct Details: Sendable {
        struct Analysis: Decodable, Sendable {
            struct Section: Decodable, Sendable { let index: Int; let label: String?; let start: Double; let end: Double }
            let sections: [Section]
        }
        let value: MusicvideoProductionExtensionV2
        let names: [String: String]
        let sections: [String: Analysis.Section]
        func name(_ id: String) -> String { names[id] ?? Self.readable(id) }
        func section(_ id: String) -> String {
            guard let section = sections[id] else { return Self.readable(id) }
            return "\(section.label ?? "Section \(section.index + 1)") · \(MusicvideoProductionReviewView.range(section.start, section.end))"
        }
        static func readable(_ value: String) -> String {
            value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Music Video").interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
            if let failure {
                Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                Button("Reload music plan") { Task { await load() } }.buttonStyle(InlineActionButtonStyle())
            } else if let details {
                Text(details.value.visualArc.concept).textSelection(.enabled)
                DisclosureGroup("Song and final mix") { mix(details) }
                DisclosureGroup("Visual development · \(details.value.visualArc.sections.count) sections") { arc(details) }
                DisclosureGroup("Performance · \(details.value.performanceSegments.count) audio segments") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        if details.value.performanceSegments.isEmpty {
                            Text("No generated performance audio segments are planned.").foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        ForEach(details.value.performanceSegments, id: \.draft.id) { segment in performance(segment, details) }
                    }.padding(.top, AppTheme.Spacing.sm)
                }
                DisclosureGroup("Performance coverage · \(details.value.coverage.count) groups") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        if details.value.coverage.isEmpty {
                            Text("No dance, concert, instrument or staged vocal coverage is planned.").foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        ForEach(details.value.coverage, id: \.id) { item in coverage(item, details) }
                    }.padding(.top, AppTheme.Spacing.sm)
                }
            } else { ProgressView("Reading music plan…") }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.raisedColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .reviewAcceptanceProbe("production.musicvideo.review", state: details != nil && failure == nil)
        .task(id: LoadKey(root: dataRoot, projection: snapshot.projection)) { await load() }
        .onDisappear { generation = UUID() }
    }

    private func mix(_ details: Details) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            let mix = details.value.finalMix
            field("Original song", "\(mix.originalSongOccurrences) occurrence · starts at \(seconds(mix.originalSongTimelineStartSeconds))")
            field("Generated song audio", mix.providerSongAudioMuted ? "Muted in the final mix" : "Included in the final mix")
            field("Additional audio layers", mix.approvedAdditionalLayerIDs.isEmpty ? "None" : mix.approvedAdditionalLayerIDs.map(details.name).joined(separator: ", "))
            if let note = mix.creditAndUsageNote { field("Credits and usage", note) }
            ProductionInputPreview(reference: details.value.track, dataRoot: dataRoot, title: "Original song")
        }.padding(.top, AppTheme.Spacing.sm)
    }

    private func arc(_ details: Details) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(details.value.visualArc.motifs, id: \.id) { motif in
                field("Motif · \(details.name(motif.id))", motif.description)
                if !motif.setupIDs.isEmpty { field("Setups", motif.setupIDs.map(details.name).joined(separator: ", ")) }
            }
            ForEach(details.value.visualArc.sections, id: \.sectionID) { section in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(details.section(section.sectionID)).fontWeight(AppTheme.FontWeight.semibold)
                    field("Shots", shotNames(section.shotIDs))
                    field("Musical function", section.musicalFunction)
                    field("Visual function", section.visualFunction)
                    field("Lyrics", section.lyricsRelation == .unused ? "Not used visually" : section.lyricsRelation.rawValue.capitalized)
                    if !section.motifIDs.isEmpty { field("Motifs", section.motifIDs.map(details.name).joined(separator: ", ")) }
                    parameters("Preserved", section.constants, details)
                    parameters("Changed", section.variations, details)
                    field("Development", section.changeExplanation)
                }
            }
        }.padding(.top, AppTheme.Spacing.sm)
    }

    private func performance(_ segment: MaterializedMusicPerformanceSegmentV1, _ details: Details) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            let draft = segment.draft
            let start = Double(draft.sourceStartSample) / Double(draft.sampleRate)
            let end = Double(draft.sourceEndSample) / Double(draft.sampleRate)
            Text("\(shotNames(draft.shotIDs)) · \(purpose(draft.purpose))").fontWeight(AppTheme.FontWeight.semibold)
            field("Song range", Self.range(start, end))
            field("Timeline start", seconds(draft.timelineStartSeconds))
            if !draft.performerIDs.isEmpty { field("Performers", draft.performerIDs.map(details.name).joined(separator: ", ")) }
            if !draft.audibleVoiceIDs.isEmpty { field("Audible voices", draft.audibleVoiceIDs.map(details.name).joined(separator: ", ")) }
            ForEach(Array(draft.mouthOwnership.enumerated()), id: \.offset) { _, mouth in
                field("Mouth and voice", "\(details.name(mouth.performerID)) → \(details.name(mouth.voiceID)) · \(Self.range(mouth.timelineStartSeconds, mouth.timelineEndSeconds))")
            }
            field("Phrase boundary", draft.phraseBoundaryEvidence)
            if draft.lyricsAlignmentPath != nil { Text("Uses the approved lyrics alignment").foregroundStyle(AppTheme.Text.secondaryColor) }
            ProductionInputPreview(reference: .init(id: draft.id, role: "musicvideo.performance-audio",
                path: segment.segmentPath, sha256: segment.segmentSHA256), dataRoot: dataRoot, title: "Performance audio")
        }
    }

    private func coverage(_ item: MusicPerformanceCoverageItemV1, _ details: Details) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(Details.readable(item.kind.rawValue).capitalized).fontWeight(AppTheme.FontWeight.semibold)
            field("Song sections", item.sectionIDs.map(details.section).joined(separator: "\n"))
            field("Required coverage", item.requiredRoleIDs.map(Details.readable).joined(separator: ", "))
            ForEach(item.evidence, id: \.roleID) { evidence in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    field(Details.readable(evidence.roleID).capitalized,
                        "\(shotNames(evidence.shotIDs)) · at least \(seconds(evidence.minimumContinuousSeconds)) continuously")
                    if !evidence.performerIDs.isEmpty { field("Performers", evidence.performerIDs.map(details.name).joined(separator: ", ")) }
                    if !evidence.setupIDs.isEmpty { field("Setups", evidence.setupIDs.map(details.name).joined(separator: ", ")) }
                    if item.kind == .dance {
                        field("Framing", "Full body: \(evidence.showsFullBody ? "yes" : "no") · floor contact: \(evidence.showsFloorContact ? "yes" : "no")")
                    }
                    if let instrument = evidence.instrumentID {
                        field("Instrument", details.name(instrument))
                        field("Hands and orientation", evidence.showsHandsAndOrientation ? "Visible" : "Not visible")
                    }
                    field("Assembly role", Details.readable(evidence.assemblyRoleID))
                }
            }
            if !item.approvedExceptionRoleIDs.isEmpty {
                field("Approved exceptions", item.approvedExceptionRoleIDs.map(Details.readable).joined(separator: ", "))
            }
            if !item.choreographyBeatIDs.isEmpty { field("Choreography beats", item.choreographyBeatIDs.map(Details.readable).joined(separator: ", ")) }
            if let risk = item.risk { field("Risk", risk) }
            if let rescue = item.rescue { field("Rescue", rescue) }
        }
    }

    private func parameters(_ title: String, _ values: [MusicArcParameterV1], _ details: Details) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            field("\(title) · \(value.kind.rawValue.capitalized) · \(details.name(value.targetID))", "\(value.value)\n\(value.rationale)")
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(title).foregroundStyle(AppTheme.Text.secondaryColor)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shotNames(_ ids: [String]) -> String {
        ids.map { snapshot.number($0).map { "Shot \($0)" } ?? "Unavailable shot" }.joined(separator: ", ")
    }

    private func purpose(_ value: MusicPerformancePurposeV1) -> String {
        switch value { case .timingOnly: "Timing reference"; case .performedSong: "Performed song"; case .dialogueDiegetic: "Dialogue / scene audio" }
    }

    private func seconds(_ value: Double) -> String { String(format: "%.3f s", value) }
    nonisolated private static func range(_ start: Double, _ end: Double) -> String { String(format: "%.3f–%.3f s", start, end) }

    private func load() async {
        let token = UUID(); generation = token; details = nil; failure = nil
        do {
            let projection = snapshot.projection, root = dataRoot
            let loaded = try await Task.detached(priority: .userInitiated) {
                let value = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: root)
                let bible = try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile)
                let analysis = try JSONDecoder().decode(Details.Analysis.self, from: Data(contentsOf:
                    ProjectLocalFile.requireHash(value.analysis.sha256, at: value.analysis.path, dataRoot: root)))
                var names: [String: String] = [:]
                for character in bible.characters { names[character.id] = character.name }
                for ensemble in bible.ensembles { names[ensemble.id] = ensemble.name }
                for prop in bible.props { names[prop.id] = prop.name }
                for location in bible.locations { names[location.id] = location.name }
                for scene in try SpatialSceneStore.index(in: root).scenes {
                    let revision = try SpatialSceneStore.load(scene, in: root)
                    for camera in revision.snapshot.cameras { names[camera.id] = "\(scene.name) · \(camera.name)" }
                }
                var sections: [String: Details.Analysis.Section] = [:]
                for section in analysis.sections {
                    guard sections.updateValue(section, forKey: "section-\(section.index)") == nil else {
                        throw GateBlocked("The song analysis contains duplicate sections. Repair the analysis before reviewing the music plan.")
                    }
                }
                return Details(value: value, names: names, sections: sections)
            }.value
            guard generation == token, !Task.isCancelled else { return }
            details = loaded
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            failure = "The music plan is unavailable or has changed. Prepare the Music Video Shot List again before approving it. \(error.localizedDescription)"
        }
    }
}
