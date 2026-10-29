import AVFoundation
import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionAssemblyWriter {
    nonisolated static let receiptPath = "execution/extensions/production-plan-assembly-host.v1.json"

    struct MediaBinding: Codable, Sendable, Equatable {
        let mediaID: String
        let source: CanonicalArtifactReferenceV1
    }

    struct Receipt: Codable, Sendable, Equatable {
        let schema: String
        let projectKey: String
        let workflow: HostWorkflowKey
        let assembly: CanonicalArtifactReferenceV1
        let fps: Int
        let tracks: [Track]
        let media: [MediaBinding]
        let audioPreparation: CanonicalArtifactReferenceV1?
        let soundtrackTrackID: String?
        let linkedAudio: [String: String]
        var additionalAudio: [PipelineProductionMusicMix.Layer]? = nil
        var musicCoverage: [PipelineProductionMusicCoverage.Binding]? = nil
    }

    struct ExistingMedia: Sendable, Equatable {
        let id: String
        let path: String
        let url: URL
        let type: ClipType
    }

    struct Context: Sendable, Equatable {
        let home: URL
        let projectKey: String
        let workingCopyKey: String
        let declaration: ProjectPackGate.MutationDeclaration
        let timeline: Timeline
        let manifest: MediaManifest
        let media: [ExistingMedia]

        @MainActor
        init(editor: EditorViewModel) throws {
            guard let home = editor.workingRoot, let projectKey = editor.projectId,
                  let key = editor.openWorkingCopyKey else { throw changed() }
            self.home = home; self.projectKey = projectKey; workingCopyKey = key
            declaration = .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                productionContract: editor.declaredProductionContract)
            timeline = editor.timeline; manifest = editor.mediaManifest
            media = editor.mediaAssets.map { .init(id: $0.id, path: FrameInventory.relativePath(of: $0.url, to: home), url: $0.url, type: $0.type) }
        }

        @MainActor
        func requireCurrent(editor: EditorViewModel) throws {
            guard try Context(editor: editor) == self else { throw changed() }
        }
    }

    struct PreparedMedia: Sendable {
        let id: String
        let path: String
        let type: ClipType
        let name: String
        let duration: Double
        let sourceWidth: Int?
        let sourceHeight: Int?
        let hasAudio: Bool

        func fitTransform(canvasWidth: Int, canvasHeight: Int) -> Transform {
            guard let width = sourceWidth, let height = sourceHeight, width > 0, height > 0,
                  canvasWidth > 0, canvasHeight > 0 else { return Transform() }
            let sourceAspect = Double(width) / Double(height), canvasAspect = Double(canvasWidth) / Double(canvasHeight)
            if abs(sourceAspect - canvasAspect) < Defaults.aspectTolerance { return Transform() }
            return sourceAspect > canvasAspect ? Transform(width: 1, height: canvasAspect / sourceAspect)
                : Transform(width: sourceAspect / canvasAspect, height: 1)
        }
    }

    struct Prepared: Sendable {
        let proof: ProductionPlanAssemblyProofV1
        let timeline: Timeline
        let media: [PreparedMedia]
    }

    static func assemble(editor: EditorViewModel, access: PipelinePlanningWriteAccess, driftAction: String?,
                         reviewedRanges: [String: String] = [:], validateCommit: (() throws -> Void)? = nil, didCommit: (() -> Void)? = nil) async throws -> ProductionPlanAssemblyProofV1 {
        guard access.phase == "render" else { throw changed() }
        let context = try Context(editor: editor)
        let root = access.dataRoot
        guard FrameInventory.projectHome(of: root) == context.home, access.declaration == context.declaration else { throw changed() }
        let declaration = access.declaration
        let preparation = Task.detached(priority: .userInitiated) {
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root,
                additionalCanonicalPaths: ["shotlist", RenderReviewV1.currentPath, receiptPath,
                    ProductionPlanAssemblyProofV1.relativePath, PlaybackRangeV1.currentPath])
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: root) { $0 }
            do {
                let writer = try PipelinePlanningWriteAccess(dataRoot: transaction.output, declaration: declaration, phase: "render")
                let result = try await prepare(context: context, access: writer, driftAction: driftAction, reviewedRanges: reviewedRanges)
                try fence.requireUnchanged()
                return (transaction, result, fence)
            } catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        let assets = result.1.media.reduce(into: [String: MediaAsset]()) { assets, value in
            guard !context.media.contains(where: { $0.id == value.id }), assets[value.id] == nil else { return }
            let asset = MediaAsset(id: value.id, url: context.home.appendingPathComponent(value.path), type: value.type,
                name: value.name, duration: value.duration)
            asset.sourceWidth = value.sourceWidth; asset.sourceHeight = value.sourceHeight; asset.hasAudio = value.hasAudio
            assets[value.id] = asset
        }
        try editor.withTimelineSwap(actionName: "Assemble Production") {
            _ = try result.0.commit { _ in
                try context.requireCurrent(editor: editor)
                try validateCommit?()
                try result.2.requireCanonicalRootsUnchanged()
                try ProjectWorkingCopy.markDirty(key: context.workingCopyKey)
            }
            for asset in assets.values { editor.importMediaAsset(asset) }
            editor.timeline = result.1.timeline
            didCommit?()
        }
        return result.1.proof
    }

    nonisolated private static func prepare(context: Context, access: PipelinePlanningWriteAccess,
        driftAction: String?, reviewedRanges: [String: String]) async throws -> Prepared {
        let root = access.dataRoot
        let projectKey = context.projectKey
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        let board = try PlanningWriterIO.storyboard(dataRoot: root)
        guard projection.timebase.fpsNumerator % projection.timebase.fpsDenominator == 0,
              let fps = Int(exactly: projection.timebase.fpsNumerator / projection.timebase.fpsDenominator), fps > 0,
              context.timeline.fps == fps, let review = try PipelineRenderReviewWriter.loadIfPresent(dataRoot: root) else {
            throw GateBlocked("The timeline frame rate must match the production plan exactly before assembly.")
        }
        try PipelineRenderReviewWriter.requireCurrent(review, root)
        let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
        try GateGuard.requirePriorApproved(gates, order: PhaseContractRuntime.order(workflow: access.workflow), phase: "render")
        let previous: Receipt?
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(receiptPath).path) {
            previous = try PlanningWriterIO.read(Receipt.self, at: receiptPath, dataRoot: root)
            guard let previous, previous.schema == "production-assembly-host/v1", previous.projectKey == projectKey,
                  previous.workflow == access.workflow else { throw changed() }
            let current = previous.tracks.compactMap { expected in context.timeline.tracks.first(where: { $0.id == expected.id }) }
            if try !tracksEqual(current, previous.tracks), driftAction != "rebuild" {
                throw GateBlocked("The assembled tracks were edited. Keep the current cut for final review, or explicitly choose rebuild to replace these tracks from the production plan.")
            }
            if driftAction != "rebuild", try tracksEqual(current, previous.tracks), let proof = try? requireCurrent(dataRoot: root) {
                var urls: [String: URL] = [:]
                for item in context.media { urls[item.id] = FrameInventory.projectHome(of: root).appendingPathComponent(item.path) }
                try requireTimeline(previous, timeline: context.timeline, mediaURLs: urls, exactVisuals: true)
                return Prepared(proof: proof, timeline: context.timeline, media: [])
            }
        } else { previous = nil }
        let startupSongTrack: String?
        if access.workflow.packID == "musicvideo", let source = board.timing.audio?.source {
            startupSongTrack = try PipelineProductionMusicMix.startupSongTrack(timeline: context.timeline,
                manifest: context.manifest, media: context.media, source: source)
        } else { startupSongTrack = nil }
        var tracks: [Track] = []
        var placements: [ProductionPlanAssemblyProofV1.Placement] = []
        var mediaBindings: [MediaBinding] = []
        var refs: [CanonicalArtifactReferenceV1] = []
        var linkedAudio: [String: String] = [:]
        var preparedAssets: [PreparedMedia] = []
        let mainVideoID = previous?.tracks.first(where: { $0.type == .video })?.id ?? UUID().uuidString
        if projection.mode != .multicam { tracks.append(Track(id: mainVideoID, type: .video)) }
        for (number, shot) in projection.shots.enumerated() {
            guard let timing = projection.timing(for: shot.id) else { throw changed() }
            let output: CanonicalArtifactReferenceV1
            let takeID: String?, selection: CanonicalArtifactReferenceV1?, submission: CanonicalArtifactReferenceV1?, delivery: CanonicalArtifactReferenceV1?
            let still = ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill
            var nativeRange: CanonicalArtifactReferenceV1?
            var selectedSourceRange: PipelineProductionRenderWriter.SourceRange?
            if shot.sourceMode == .imported {
                guard let source = projection.source(for: shot.id) else { throw changed() }
                output = source; takeID = nil; selection = nil; submission = nil; delivery = nil
            } else if still {
                let actual = try PipelineProductionRenderWriter.requireStill(shotID: shot.id, dataRoot: root)
                output = actual.record.output; takeID = actual.reference.id; selection = actual.reference
                submission = nil; delivery = actual.record.frameReceipt
                refs += [actual.reference, actual.record.projection, actual.record.frameReceipt, actual.record.renderReview]
            } else {
                let actual = try PipelineProductionRenderWriter.requireSelected(shotID: shot.id, dataRoot: root)
                output = actual.record.output; takeID = actual.record.takeID; selection = actual.reference
                submission = actual.record.submission; delivery = actual.selection.record
                nativeRange = actual.selection.nativeRange
                if let requested = reviewedRanges[shot.id], requested != nativeRange?.id { throw changed() }
                if let nativeRange {
                    selectedSourceRange = try PipelineProductionRenderWriter.sourceRange(record: actual.record, selection: actual.selection, dataRoot: root)
                    refs.append(nativeRange)
                }
                refs += [actual.reference, actual.selection.record, actual.selection.review, actual.record.generation,
                    actual.record.projection, actual.record.submission]
            }
            refs += try PipelineProductionPerformanceAlignment.requireCurrent(shotID: shot.id, projection: projection, dataRoot: root)
            let asset = try await media(output, name: "Shot \(number + 1)", type: still ? .image : .video, context: context, access: access)
            preparedAssets.append(asset)
            let start = try frame(timing.startTicks, timebase: projection.timebase)
            let duration = try count(timing.durationTicks, timebase: projection.timebase)
            let sourceIn: Int
            if let nativeRange {
                let range = try ReviewedTakeRange.load(id: nativeRange.id, dataRoot: root)
                guard range.range.fps == fps, range.range.endFrame - range.range.startFrame == duration else { throw changed() }
                sourceIn = range.range.startFrame
            } else { sourceIn = try frame(timing.sourceInTicks, timebase: projection.timebase) }
            let decoded: Int64?
            if still { decoded = nil }
            else if let selectedSourceRange { decoded = selectedSourceRange.fullDurationTicks }
            else {
                let url = try ProjectLocalFile.resolve(output.path, dataRoot: root)
                decoded = try await Task.detached(priority: .userInitiated) {
                    let actual = try await AVURLAsset(url: url).load(.duration)
                    guard actual.isNumeric, actual.value > 0, projection.timebase.ticksPerSecond <= Int64(Int32.max) else { throw changed() }
                    let end = timing.sourceInTicks.addingReportingOverflow(timing.durationTicks)
                    guard !end.overflow, CMTimeCompare(actual, CMTime(value: end.partialValue,
                        timescale: Int32(projection.timebase.ticksPerSecond))) >= 0 else { throw changed() }
                    return CMTimeConvertScale(actual, timescale: Int32(projection.timebase.ticksPerSecond), method: .roundTowardZero).value
                }.value
            }
            let trackID = projection.mode == .multicam
                ? (previous?.tracks.filter { $0.type == .video }.dropFirst(number).first?.id ?? UUID().uuidString) : mainVideoID
            if projection.mode == .multicam { tracks.append(Track(id: trackID, type: .video)) }
            guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { throw changed() }
            var clip = Clip(mediaRef: asset.id, mediaType: asset.type, sourceClipType: asset.type,
                startFrame: start, durationFrames: duration, trimStartFrame: sourceIn,
                trimEndFrame: max(0, Int((asset.duration * Double(fps)).rounded(.down)) - sourceIn - duration),
                transform: asset.fitTransform(canvasWidth: context.timeline.width, canvasHeight: context.timeline.height))
            if access.workflow.packID == "musicvideo" { clip.volume = 0 }
            let motion: TimelineAssemblyProofV1.Placement.Motion?
            if still {
                guard duration > 1 else { throw GateBlocked("An animated still needs at least two timeline frames for its planned movement.") }
                let scale = 1.08
                let initial = AnimPair(a: clip.transform.width, b: clip.transform.height)
                let final = AnimPair(a: initial.a * scale, b: initial.b * scale)
                clip.scaleTrack = .init(keyframes: [.init(frame: 0, value: initial, interpolationOut: .linear),
                    .init(frame: duration - 1, value: final, interpolationOut: .linear)])
                clip.positionTrack = .init(keyframes: [.init(frame: 0,
                    value: AnimPair(a: clip.transform.topLeft.x, b: clip.transform.topLeft.y), interpolationOut: .linear),
                    .init(frame: duration - 1, value: AnimPair(a: 0.5 - final.a / 2, b: 0.5 - final.b / 2), interpolationOut: .linear)])
                motion = .init(kind: .kenBurnsZoom, startScale: 1, endScale: scale)
            } else { motion = nil }
            if access.workflow.packID == nil, !still, asset.hasAudio,
               shot.sourceMode == .imported || shot.generationRequirement?.requiresOutputAudio == true {
                let link = UUID().uuidString
                clip.linkGroupId = link
                var audioClip = Clip(mediaRef: asset.id, mediaType: .audio, sourceClipType: .video,
                    startFrame: clip.startFrame, durationFrames: clip.durationFrames,
                    trimStartFrame: clip.trimStartFrame, trimEndFrame: clip.trimEndFrame)
                audioClip.linkGroupId = link
                linkedAudio[clip.id] = audioClip.id
                tracks.append(Track(type: .audio, clips: [audioClip]))
            }
            tracks[index].clips.append(clip)
            placements.append(.init(shotID: shot.id, trackID: trackID, clipID: clip.id, output: output,
                sourceKind: still ? .stillImage : .video, startTicks: timing.startTicks, durationTicks: timing.durationTicks,
                sourceInTicks: selectedSourceRange?.startTicks ?? timing.sourceInTicks, decodedDurationTicks: decoded, motion: motion,
                takeID: takeID, selectionReceipt: selection, submissionBinding: submission, deliveryProof: delivery,
                nativeRange: nativeRange, sourceTimebase: selectedSourceRange?.timebase))
            mediaBindings.append(.init(mediaID: asset.id, source: output))
            refs.append(output)
        }
        guard Set(reviewedRanges.keys).isSubset(of: Set(projection.shots.map(\.id))) else { throw changed() }
        let audio: ProductionPlanAssemblyProofV1.AudioPlacement?
        let audioPreparation: CanonicalArtifactReferenceV1?
        if let planned = board.timing.audio {
            let rangeEnd = board.timing.rangeStartTicks.addingReportingOverflow(board.timing.rangeDurationTicks)
            let sourceEnd = planned.offsetTicks.addingReportingOverflow(planned.durationTicks)
            guard !rangeEnd.overflow, !sourceEnd.overflow else { throw changed() }
            let start = max(board.timing.rangeStartTicks, planned.offsetTicks)
            let end = min(rangeEnd.partialValue, sourceEnd.partialValue)
            if start < end {
                guard let sourceIn = planned.sourceTick(atTimelineTick: start) else { throw changed() }
                let prepared = try await PipelineProductionInputMedia.prepare(.init(source: planned.source,
                    timebase: projection.timebase, startTicks: sourceIn, durationTicks: end - start, modality: .audio), access: access)
                let value = try PlanningWriterIO.read(PipelineProductionInputMedia.Receipt.self, at: prepared.path, dataRoot: root)
                let asset = try await media(value.output, name: "Production soundtrack", type: .audio, context: context, access: access)
                preparedAssets.append(asset)
                let audioID = previous?.soundtrackTrackID ?? startupSongTrack ?? UUID().uuidString
                let clip = Clip(mediaRef: asset.id, mediaType: .audio, sourceClipType: .audio,
                    startFrame: try frame(start, timebase: projection.timebase), durationFrames: try count(end - start, timebase: projection.timebase))
                tracks.append(Track(id: audioID, type: .audio, clips: [clip]))
                audio = .init(trackID: audioID, clipID: clip.id, source: planned.source,
                    startTicks: start, sourceInTicks: sourceIn, durationTicks: end - start)
                audioPreparation = prepared
                mediaBindings.append(.init(mediaID: asset.id, source: value.output))
                refs += [prepared, planned.source, value.output]
            } else { audio = nil; audioPreparation = nil }
        } else { audio = nil; audioPreparation = nil }
        let musicMix = try await PipelineProductionMusicMix.prepare(projection: projection, context: context, dataRoot: root)
        if let musicMix {
            tracks += musicMix.tracks
            mediaBindings += musicMix.media
            refs += musicMix.references
        }
        let planRef = try PlanningWriterIO.reference(ProductionPlanProjectionV1.versionPath(projection.header.revision),
            id: "production-plan", role: "core.production-plan", dataRoot: root)
        let reviewRef = try PlanningWriterIO.reference(RenderReviewV1.versionPath(review.header.revision),
            id: "render-review", role: "core.render-review", dataRoot: root)
        refs += [planRef, reviewRef]
        let range: PlaybackRangeV1?
        let rangeURL = root.appendingPathComponent(PlaybackRangeV1.currentPath)
        if FileManager.default.fileExists(atPath: rangeURL.path) {
            range = try PlanningWriterIO.read(PlaybackRangeV1.self, at: PlaybackRangeV1.currentPath, dataRoot: root)
            guard let range else { throw changed() }
            try PipelinePlaybackRangeWriter.requireCanonicalCurrent(range, dataRoot: root, workflowID: access.workflow.contractID)
            refs += range.header.inputs + [range.analysis] + [range.selectionReceipt].compactMap { $0 }
            refs.append(try PlanningWriterIO.reference(PlaybackRangeV1.currentPath, id: "output-range", role: "core.playback-range", dataRoot: root))
        } else { range = nil }
        let inputs = try unique([planRef, reviewRef] + refs)
        let proof = ProductionPlanAssemblyProofV1(header: .init(projectID: projection.header.projectID,
            revision: projection.header.revision, origin: .agentProposal, inputs: inputs),
            productionPlan: planRef, renderReview: reviewRef, timebase: projection.timebase,
            placements: placements, audio: audio, outputRange: range)
        try ProductionPlanAssemblyV1.validate(proof, projection: projection, timing: board.timing)
        let proofBytes = try PlanningWriterIO.json(proof)
        tracks = orderedTracks(tracks)
        let receipt = Receipt(schema: "production-assembly-host/v1", projectKey: projectKey, workflow: access.workflow,
            assembly: PlanningWriterIO.reference(ProductionPlanAssemblyProofV1.relativePath, id: "assembly", role: "core.production-assembly", bytes: proofBytes),
            fps: fps, tracks: tracks, media: mediaBindings, audioPreparation: audioPreparation,
            soundtrackTrackID: audio?.trackID, linkedAudio: linkedAudio, additionalAudio: musicMix?.layers,
            musicCoverage: musicMix == nil ? nil : try PipelineProductionMusicCoverage.bindings(projection: projection, proof: proof, dataRoot: root))
        let oldIDs = Set((previous?.tracks.map(\.id) ?? []) + (musicMix?.tracks.map(\.id) ?? []) + [startupSongTrack].compactMap { $0 })
        try PipelineProductionMusicMix.requireNoForeignTracks(context.timeline, owned: oldIDs)
        var timeline = context.timeline
        timeline.tracks.removeAll { oldIDs.contains($0.id) }
        timeline.tracks.insert(contentsOf: tracks.filter { $0.type == .video }, at: 0)
        timeline.tracks.append(contentsOf: tracks.filter { $0.type == .audio })
        var urls: [String: URL] = [:]
        for binding in receipt.media { urls[binding.mediaID] = try ProjectLocalFile.resolve(binding.source.path, dataRoot: root) }
        try requireTimeline(receipt, timeline: timeline, mediaURLs: urls, exactVisuals: true)
        try access.publish([(ProductionPlanAssemblyProofV1.relativePath, proofBytes),
            (receiptPath, try PlanningWriterIO.json(receipt))]) {
            _ = try requireCurrent(dataRoot: root)
        }
        return Prepared(proof: proof, timeline: timeline, media: preparedAssets)
    }

    nonisolated static func requireCurrent(dataRoot: URL) throws -> ProductionPlanAssemblyProofV1 {
        try ProductionPlanAssemblyV1.requireCurrent(projection: ProductionPlanningLineageV2.projection(dataRoot: dataRoot),
            dataRoot: dataRoot, evidenceVerifier: verify)
    }

    nonisolated static func exportRange(dataRoot: URL, timeline: Timeline) throws -> CMTimeRange {
        let proof = try requireCurrent(dataRoot: dataRoot)
        let receipt = try PlanningWriterIO.read(Receipt.self, at: receiptPath, dataRoot: dataRoot)
        let gates = try YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        try requireTimeline(receipt, timeline: timeline, mediaURLs: nil, exactVisuals: !gates.get("render").approved)
        let board = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let range = try ProductionPlanAssemblyV1.outputInterval(proof: proof, timing: board.timing)
        guard proof.timebase.ticksPerSecond <= Int64(Int32.max) else { throw changed() }
        let clock = Int32(proof.timebase.ticksPerSecond)
        return CMTimeRange(start: CMTime(value: range.startTicks, timescale: clock), duration: CMTime(value: range.durationTicks, timescale: clock))
    }

    nonisolated static func requireExportTimeline(dataRoot: URL, timeline: Timeline, mediaURLs: [String: URL]) throws {
        _ = try requireCurrent(dataRoot: dataRoot)
        let receipt = try PlanningWriterIO.read(Receipt.self, at: receiptPath, dataRoot: dataRoot)
        let gates = try YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        try requireTimeline(receipt, timeline: timeline, mediaURLs: mediaURLs, exactVisuals: !gates.get("render").approved)
    }

    nonisolated static func requireCurrentTimeline(dataRoot: URL, timeline: Timeline, mediaURLs: [String: URL]) throws {
        _ = try requireCurrent(dataRoot: dataRoot)
        let receipt = try PlanningWriterIO.read(Receipt.self, at: receiptPath, dataRoot: dataRoot)
        try requireTimeline(receipt, timeline: timeline, mediaURLs: mediaURLs, exactVisuals: true)
    }

    nonisolated static func artifactReferences(dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        let proof = try requireCurrent(dataRoot: dataRoot)
        let receipt = try PlanningWriterIO.read(Receipt.self, at: receiptPath, dataRoot: dataRoot)
        return try unique(proof.artifactReferences + receipt.media.map(\.source) + [receipt.audioPreparation].compactMap { $0 }
            + [PlanningWriterIO.reference(receiptPath, id: "host-assembly", role: "host.production-assembly", dataRoot: dataRoot),
               PlanningWriterIO.reference(ProductionPlanAssemblyProofV1.relativePath, id: "assembly", role: "core.production-assembly", dataRoot: dataRoot)])
    }

    nonisolated private static func verify(_ proof: ProductionPlanAssemblyProofV1, _ root: URL) throws {
        let receipt = try PlanningWriterIO.read(Receipt.self, at: receiptPath, dataRoot: root)
        let home = FrameInventory.projectHome(of: root)
        let declaration = try ProjectPackGate.captureMutationDeclaration(projectURL: home)
        guard receipt.schema == "production-assembly-host/v1", receipt.projectKey == ProjectIdentity.existingUUID(for: home),
              try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: declaration.binding,
                expectedProductionContract: declaration.productionContract) == receipt.workflow,
              receipt.assembly.path == ProductionPlanAssemblyProofV1.relativePath,
              receipt.assembly.sha256 == FileDigest.sha256(of: try PlanningWriterIO.json(proof)),
              let reviewed = try PipelineRenderReviewWriter.loadIfPresent(dataRoot: root) else { throw changed() }
        try PipelineRenderReviewWriter.requireCurrent(reviewed, root)
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        for shot in projection.shots {
            let alignment = try PipelineProductionPerformanceAlignment.requireCurrent(shotID: shot.id, projection: projection, dataRoot: root)
            guard alignment.allSatisfy({ reference in proof.header.inputs.contains { $0.path == reference.path && $0.sha256 == reference.sha256 } }) else { throw changed() }
        }
        for placement in proof.placements {
            if placement.sourceKind == .stillImage {
                let actual = try PipelineProductionRenderWriter.requireStill(shotID: placement.shotID, dataRoot: root)
                guard placement.output == actual.record.output, placement.takeID == actual.reference.id,
                      placement.selectionReceipt == actual.reference, placement.deliveryProof == actual.record.frameReceipt else { throw changed() }
            } else if placement.takeID != nil {
                let actual = try PipelineProductionRenderWriter.requireSelected(shotID: placement.shotID, dataRoot: root)
                guard placement.output == actual.record.output, placement.takeID == actual.record.takeID,
                      placement.selectionReceipt == actual.reference, placement.submissionBinding == actual.record.submission,
                      placement.nativeRange == actual.selection.nativeRange else { throw changed() }
                if placement.nativeRange != nil {
                    let range = try PipelineProductionRenderWriter.sourceRange(record: actual.record, selection: actual.selection, dataRoot: root)
                    guard placement.sourceTimebase == range.timebase, placement.sourceInTicks == range.startTicks,
                          placement.decodedDurationTicks == range.fullDurationTicks else { throw changed() }
                }
            }
        }
        if let audio = proof.audio {
            guard let prepared = receipt.audioPreparation else { throw changed() }
            let value = try PlanningWriterIO.read(PipelineProductionInputMedia.Receipt.self, at: prepared.path, dataRoot: root)
            let expected = PipelineProductionInputMedia.Selection(source: audio.source, timebase: proof.timebase,
                startTicks: audio.sourceInTicks, durationTicks: audio.durationTicks, modality: .audio)
            try PipelineProductionInputMedia.require(value, selection: expected, dataRoot: root)
            guard let track = receipt.tracks.first(where: { $0.id == audio.trackID }),
                  let clip = track.clips.first(where: { $0.id == audio.clipID }),
                  receipt.media.contains(.init(mediaID: clip.mediaRef, source: value.output)) else { throw changed() }
        } else if receipt.audioPreparation != nil { throw changed() }
        for binding in receipt.media { _ = try ProjectLocalFile.requireHash(binding.source.sha256, at: binding.source.path, dataRoot: root) }
        if let range = proof.outputRange {
            try PipelinePlaybackRangeWriter.requireCanonicalCurrent(range, dataRoot: root, workflowID: receipt.workflow.contractID)
        }
        if receipt.workflow.packID == "musicvideo" {
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
            guard let additional = receipt.additionalAudio, let coverage = receipt.musicCoverage,
                  coverage == (try PipelineProductionMusicCoverage.bindings(projection: projection, proof: proof, dataRoot: root)) else { throw changed() }
            try PipelineProductionMusicMix.requireCurrent(additional, tracks: receipt.tracks, media: receipt.media,
                projection: projection, fps: receipt.fps, dataRoot: root)
        } else if receipt.additionalAudio != nil || receipt.musicCoverage != nil { throw changed() }
        let expectedIDs = Set(proof.placements.map(\.clipID) + [proof.audio?.clipID].compactMap { $0 }
            + Array(receipt.linkedAudio.values) + (receipt.additionalAudio?.map(\.clipID) ?? []))
        guard Set(receipt.tracks.flatMap(\.clips).map(\.id)) == expectedIDs,
              receipt.tracks.flatMap(\.clips).count == expectedIDs.count,
              receipt.fps > 0, proof.timebase.fpsDenominator > 0,
              proof.timebase.fpsNumerator % proof.timebase.fpsDenominator == 0,
              proof.timebase.fpsNumerator / proof.timebase.fpsDenominator == Int64(receipt.fps) else { throw changed() }
        for placement in proof.placements {
            guard let track = receipt.tracks.first(where: { $0.id == placement.trackID }), track.type == .video,
                  !track.muted, !track.hidden, let clip = track.clips.first(where: { $0.id == placement.clipID }),
                  clip.startFrame == (try frame(placement.startTicks, timebase: proof.timebase)),
                  clip.durationFrames == (try count(placement.durationTicks, timebase: proof.timebase)),
                  clip.speed == 1, clip.opacity == 1,
                  receipt.media.contains(.init(mediaID: clip.mediaRef, source: placement.output)),
                  receipt.workflow.packID != "musicvideo" || clip.volume == 0 else { throw changed() }
            if let rangeRef = placement.nativeRange {
                let range = try ReviewedTakeRange.load(id: rangeRef.id, dataRoot: root)
                guard range.range.fps == receipt.fps, clip.trimStartFrame == range.range.startFrame,
                      clip.durationFrames == range.range.endFrame - range.range.startFrame else { throw changed() }
            } else if clip.trimStartFrame != (try frame(placement.sourceInTicks, timebase: proof.timebase)) { throw changed() }
            if let linkedID = receipt.linkedAudio[clip.id] {
                guard receipt.workflow.packID == nil,
                      let linkedTrack = receipt.tracks.first(where: { $0.type == .audio && $0.clips.contains(where: { $0.id == linkedID }) }),
                      let linked = linkedTrack.clips.first(where: { $0.id == linkedID }),
                      linked.mediaRef == clip.mediaRef, linked.startFrame == clip.startFrame,
                      linked.durationFrames == clip.durationFrames, linked.trimStartFrame == clip.trimStartFrame,
                      linked.linkGroupId == clip.linkGroupId, linked.linkGroupId != nil else { throw changed() }
            }
        }
        guard Set(receipt.linkedAudio.keys).isSubset(of: Set(proof.placements.map(\.clipID))),
              receipt.soundtrackTrackID == proof.audio?.trackID else { throw changed() }
        if let audio = proof.audio {
            guard let track = receipt.tracks.first(where: { $0.id == audio.trackID }), track.type == .audio,
                  !track.muted, let clip = track.clips.first(where: { $0.id == audio.clipID }),
                  clip.startFrame == (try frame(audio.startTicks, timebase: proof.timebase)),
                  clip.durationFrames == (try count(audio.durationTicks, timebase: proof.timebase)),
                  clip.trimStartFrame == 0, clip.speed == 1 else { throw changed() }
        }
    }

    nonisolated static func requireTimeline(_ receipt: Receipt, timeline: Timeline,
        mediaURLs: [String: URL]?, exactVisuals: Bool) throws {
        guard timeline.fps == receipt.fps else { throw changed() }
        if exactVisuals {
            let expected = receipt.tracks.map(\.id)
            let ids = Set(expected)
            let effective = timeline.tracks.filter { track in
                if ids.contains(track.id) { return true }
                if track.clips.isEmpty { return false }
                return track.type == .audio ? !track.muted : !track.hidden
            }.map(\.id)
            guard ids.count == expected.count, effective == expected else { throw changed() }
        }
        for track in receipt.tracks {
            if !exactVisuals, track.id != receipt.soundtrackTrackID { continue }
            guard let actual = timeline.tracks.first(where: { $0.id == track.id }), actual.type == track.type else { throw changed() }
            if exactVisuals {
                guard try tracksEqual([actual], [track]) else { throw changed() }
            } else if track.id == receipt.soundtrackTrackID {
                guard !actual.muted, actual.clips.count == track.clips.count else { throw changed() }
                for expected in track.clips {
                    guard let clip = actual.clips.first(where: { $0.id == expected.id }), clip.mediaRef == expected.mediaRef,
                          clip.startFrame == expected.startFrame, clip.durationFrames == expected.durationFrames,
                          clip.trimStartFrame == expected.trimStartFrame, clip.trimEndFrame == expected.trimEndFrame,
                          clip.speed == expected.speed, clip.volume > 0 else { throw changed() }
                }
            }
            if let mediaURLs {
                for clip in actual.clips {
                    guard let binding = receipt.media.first(where: { $0.mediaID == clip.mediaRef }),
                          let actualURL = mediaURLs[clip.mediaRef],
                          try FileDigest.sha256(of: actualURL) == binding.source.sha256 else { throw changed() }
                }
            }
        }
    }

    nonisolated private static func media(_ reference: CanonicalArtifactReferenceV1, name: String, type: ClipType,
                                         context: Context, access: PipelinePlanningWriteAccess) async throws -> PreparedMedia {
        let url = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: access.dataRoot)
        let path = FrameInventory.relativePath(of: url, to: FrameInventory.projectHome(of: access.dataRoot))
        let existing = context.media.first { $0.path == path }
        guard existing == nil || existing?.type == type else { throw changed() }
        let id = existing?.id ?? "production-source:" + FileDigest.sha256(of: Data(reference.path.utf8))
        let duration: Double, width: Int?, height: Int?, hasAudio: Bool
        if type == .image {
            let image = try FrameRasterizer.loadImage(at: url)
            duration = 0; width = image.width; height = image.height; hasAudio = false
        } else {
            let asset = AVURLAsset(url: url)
            let time = try await asset.load(.duration)
            guard time.isNumeric, time.value > 0, time.seconds.isFinite,
                  context.timeline.fps > 0, time.seconds * Double(context.timeline.fps) < Double(Int.max) else { throw changed() }
            duration = time.seconds
            hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            if type == .video {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw changed() }
                let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                let actual = size.applying(transform)
                guard actual.width.isFinite, actual.height.isFinite, abs(actual.width) < Double(Int.max),
                      abs(actual.height) < Double(Int.max) else { throw changed() }
                width = Int(abs(actual.width).rounded()); height = Int(abs(actual.height).rounded())
            } else { width = nil; height = nil }
        }
        return .init(id: id, path: path, type: type, name: name, duration: duration,
            sourceWidth: width, sourceHeight: height, hasAudio: hasAudio)
    }

    nonisolated static func orderedTracks(_ tracks: [Track]) -> [Track] {
        tracks.filter { $0.type == .video } + tracks.filter { $0.type == .audio }
    }

    nonisolated private static func tracksEqual(_ lhs: [Track], _ rhs: [Track]) throws -> Bool {
        try PlanningWriterIO.json(lhs) == PlanningWriterIO.json(rhs)
    }
    nonisolated private static func frame(_ ticks: Int64, timebase: RationalTimebaseV1) throws -> Int {
        guard let value = Int(exactly: try ProductionPlanAssemblyV1.frameIndex(for: ticks, timebase: timebase)) else { throw changed() }
        return value
    }
    nonisolated private static func count(_ ticks: Int64, timebase: RationalTimebaseV1) throws -> Int {
        guard let value = Int(exactly: try ProductionPlanAssemblyV1.coveringFrameCount(for: ticks, timebase: timebase)) else { throw changed() }
        return value
    }
    nonisolated private static func unique(_ refs: [CanonicalArtifactReferenceV1]) throws -> [CanonicalArtifactReferenceV1] {
        var values: [String: CanonicalArtifactReferenceV1] = [:]
        for ref in refs {
            if let old = values[ref.path], old.sha256 != ref.sha256 { throw changed() }
            if values[ref.path] == nil { values[ref.path] = ref }
        }
        var ids = Set<String>()
        return values.values.sorted { $0.path < $1.path }.map { ref in
            if ids.insert(ref.id).inserted { return ref }
            return .init(id: ref.id + "." + FileDigest.sha256(of: Data(ref.path.utf8)),
                role: ref.role, path: ref.path, sha256: ref.sha256)
        }
    }
    nonisolated private static func changed() -> GateBlocked {
        GateBlocked("The production assembly, actual source ranges or selected takes changed. Rebuild the canonical assembly or review the current cut before exporting.")
    }
}
