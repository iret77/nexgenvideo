import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ProductionV2FilmAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver,
                    output: URL, additionalAudio: ProductionV2AudioAcceptance.Selection? = nil, requiresReviewedTake: Bool = true) async throws -> [String: Any] {
        let editor = context.editor, root = context.dataRoot, window = driver.window
        try await ProductionV2PlanningAcceptance.selectPhase("render", context: context, driver: driver)
        try await driver.wait("all native selections can be assembled", seconds: 30) {
            driver.text("production.assembly.state", in: window) == "ready"
                && driver.state("production.assembly.build", in: window) == true
        }
        let before = editor.timeline
        let songAnchor: (trackID: String, sha256: String)?
        if editor.declaredPluginBinding?.id == "musicvideo" {
            guard let id = editor.mediaManifest.songAnchorAssetId,
                  let asset = editor.mediaAssets.first(where: { $0.id == id }),
                  editor.mediaManifest.intakeRoleByAssetID[id] == "song" else {
                throw failed("The actual startup song anchor disappeared before assembly.")
            }
            let tracks = before.tracks.filter { $0.clips.contains { $0.mediaRef == id } }
            guard tracks.count == 1, let track = tracks.first, track.type == .audio,
                  !track.muted, track.clips.count == 1 else { throw failed("The actual startup song is not on one intact audio track.") }
            let url = asset.url
            songAnchor = (track.id, try await Task.detached { try FileDigest.sha256(of: url) }.value)
        } else { songAnchor = nil }
        try driver.capture("production-cut-ready", target: window)
        try await driver.click("production.assembly.build", in: window)
        try await driver.wait("native production cut completed", seconds: 90) {
            editor.timeline != before && driver.text("production.assembly.state", in: window) == "assembled"
        }
        let assembled = try await PipelineProductionAssemblyController.capture(editor: editor)
        let proof = try await Task.detached {
            try PlanningWriterIO.read(ProductionPlanAssemblyProofV1.self,
                at: ProductionPlanAssemblyProofV1.relativePath, dataRoot: root)
        }.value
        guard assembled.state == .assembled, proof.placements.count >= 2,
              (requiresReviewedTake
                ? proof.placements.contains(where: { $0.nativeRange != nil }) && proof.placements.contains(where: { $0.takeID == nil })
                : proof.placements.allSatisfy({ $0.takeID == nil && $0.nativeRange == nil })) else {
            throw failed("The native assembly did not retain both the reviewed take range and imported source.")
        }
        let receipt = try await Task.detached {
            try PlanningWriterIO.read(PipelineProductionAssemblyWriter.Receipt.self,
                at: PipelineProductionAssemblyWriter.receiptPath, dataRoot: root)
        }.value
        if let songAnchor {
            guard let song = proof.audio, song.trackID == songAnchor.trackID, song.source.sha256 == songAnchor.sha256,
                  song.startTicks == 0, song.sourceInTicks == 0, receipt.soundtrackTrackID == song.trackID,
                  let track = editor.timeline.tracks.first(where: { $0.id == song.trackID }),
                  track.type == .audio, !track.muted, track.clips.count == 1, track.clips[0].id == song.clipID,
                  Set(editor.timeline.tracks.filter { $0.type == .audio && !$0.muted }.flatMap(\.clips).map(\.id))
                    == Set([song.clipID] + (additionalAudio.map { [$0.clip.id] } ?? [])) else {
                throw failed("Assembly duplicated, moved or changed the original startup song instead of replacing its one track.")
            }
            try driver.record("original Music Video song occurs once", fields: ["startupTrackID": songAnchor.trackID,
                "canonicalTrackID": song.trackID, "clipID": song.clipID, "sourceSHA256": song.source.sha256,
                "startTicks": song.startTicks, "sourceInTicks": song.sourceInTicks, "durationTicks": song.durationTicks,
                "activeAudioClipCount": 1 + (additionalAudio == nil ? 0 : 1)])
        }
        if let additionalAudio {
            guard let track = editor.timeline.tracks.first(where: { $0.id == additionalAudio.trackID }),
                  track.type == .audio, !track.muted,
                  track.clips.first(where: { $0.id == additionalAudio.clip.id }) == additionalAudio.clip,
                  let layer = receipt.additionalAudio?.first(where: { $0.clipID == additionalAudio.clip.id }),
                  receipt.additionalAudio?.count == 1, layer.trackID == additionalAudio.trackID,
                  layer.source.sha256 == additionalAudio.sha256, layer.source.path == additionalAudio.path else {
                throw failed("Assembly did not preserve the actual natively inserted and levelled additional audio clip.")
            }
            try driver.record("native Music Video audio preserved by assembly", fields: ["clipID": additionalAudio.clip.id,
                "trackID": additionalAudio.trackID, "sourceSHA256": additionalAudio.sha256,
                "startFrame": additionalAudio.clip.startFrame, "trimStartFrame": additionalAudio.clip.trimStartFrame,
                "durationFrames": additionalAudio.clip.durationFrames, "volume": additionalAudio.clip.volume])
        }
        try driver.record("native production assembly", fields: ["fingerprint": assembled.fingerprint,
            "shotIDs": proof.placements.map(\.shotID), "clipIDs": proof.placements.map(\.clipID)])
        try await ProductionV2PlanningAcceptance.approve("render", artifact: PipelineLayout.renderManifestFile(phase: "final"),
            next: nil, context: context, driver: driver)
        try await driver.wait("approved production film surface") {
            driver.text("production.render.review-surface", in: window) == "film"
                && driver.state("sequence.build", in: window) == true
        }
        let review = try await reviewFilm(context: context, driver: driver, proof: proof)
        let style = try await reviewStyle(context: context, driver: driver)
        let result = try await export(context: context, driver: driver, proof: proof, review: review, output: output)
        return result.merging(["nativeAssembly": true, "nativeFullFilmReview": true,
            "reviewedBoundaries": review.cutFrames, "reviewFilmSHA256": review.reel.sha256,
            "nativeStyleReview": true, "styleFingerprint": style.fingerprint, "styleFindingCount": style.findings.count]) { _, new in new }
    }

    private static func reviewFilm(context: ProductionPlanningAcceptanceFixture.Context,
                                   driver: ProductionVisualSourcesDriver,
                                   proof: ProductionPlanAssemblyProofV1) async throws -> ProductionSequenceReviewV2 {
        let editor = context.editor, window = driver.window, root = context.dataRoot
        let board = try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root) }.value
        let interval = try ProductionPlanAssemblyV1.outputInterval(proof: proof, timing: board.timing)
        let duration = try ProductionPlanAssemblyV1.coveringFrameCount(for: interval.durationTicks, timebase: proof.timebase)
        let fps = proof.timebase.framesPerSecond
        guard duration > 0, duration < Int64(Int.max), fps > 0 else { throw failed("The planned film has no bounded frame interval.") }
        let frames = Int(duration)
        let cuts = try proof.placements.dropFirst().map {
            Int(try ProductionPlanAssemblyV1.frameIndex(for: $0.startTicks - interval.startTicks, timebase: proof.timebase))
        }.filter { $0 > 0 && $0 < frames }
        guard !cuts.isEmpty else { throw failed("The owner film acceptance requires an actual picture boundary.") }
        try await driver.click("sequence.build", in: window)
        try await driver.wait("actual review movie decoded", seconds: 90) {
            ProductionNativePlaybackAcceptance.player("sequence.player", in: window)?.currentItem?.status == .readyToPlay
                && driver.state("sequence.whole", in: window) == false
        }
        guard let player = ProductionNativePlaybackAcceptance.player("sequence.player", in: window),
              player.currentTime().seconds < 1 / fps,
              let item = player.currentItem else { throw failed("The new film did not open at its first frame.") }
        let decodedDuration = try await item.asset.load(.duration)
        guard abs(decodedDuration.seconds - Double(frames) / fps) <= 1 / fps else {
            throw failed("The visible review film does not span the planned output interval.")
        }
        try await driver.reveal("sequence.play", in: window)
        try driver.visible(["sequence.play", "sequence.pause"], in: window)
        try driver.capture("review-film-first-frame", target: window)
        try await driver.click("sequence.play", in: window)
        try await driver.wait("whole film playback started") { player.rate > 0 && player.currentTime().seconds > 0 }
        try await driver.wait("whole film reached its final frame", seconds: decodedDuration.seconds + 10) {
            player.currentTime().seconds >= Double(frames - 1) / fps
        }
        try await driver.click("sequence.pause", in: window)
        try await driver.click("sequence.whole", in: window, enabled: false)
        try await driver.wait("whole film explicitly confirmed") { driver.state("sequence.whole", in: window) == true }
        try driver.record("complete native film playback", fields: ["firstFrame": 0, "endFrame": frames,
            "observedSeconds": player.currentTime().seconds, "decodedSeconds": decodedDuration.seconds])
        try await driver.picker("sequence.severity", title: "Info", expected: SequenceReviewSeverityV1.info.rawValue, in: window)
        try await driver.picker("sequence.action", title: "Accept", expected: SequenceReviewActionV1.accept.rawValue, in: window)
        let wholeObservation = "The complete native V2 film played from its first to last frame; picture and the intended source sound were checked."
        try await addFinding(start: 0, end: frames, observation: wholeObservation, driver: driver)
        for cut in cuts {
            try await driver.picker("sequence.cut", title: "Frame \(cut)", expected: String(cut), in: window)
            try await driver.click("sequence.inspect-boundary", in: window)
            let start = max(0, cut - Int(fps.rounded(.up))), end = min(frames, cut + Int(fps.rounded(.up)))
            try await driver.wait("picture boundary seek completed") {
                abs(player.currentTime().seconds - Double(start) / fps) <= 1 / fps
                    && driver.text("sequence.start", in: window) == String(start)
                    && driver.text("sequence.end", in: window) == String(end)
            }
            try await driver.click("sequence.play", in: window)
            try await driver.wait("picture boundary actually played", seconds: Double(end - start) / fps + 5) {
                player.currentTime().seconds >= Double(end - 1) / fps
            }
            try await driver.click("sequence.pause", in: window)
            try await addFinding(start: start, end: end,
                observation: "The actual cut at frame \(cut) and both adjacent pictures were played and accepted.", driver: driver)
            try driver.capture("review-boundary-\(cut)", target: window)
        }
        try await driver.click("sequence.adjacent", in: window, enabled: false)
        try await driver.wait("all picture boundaries explicitly confirmed") { driver.state("sequence.adjacent", in: window) == true }
        try await driver.click("sequence.record", in: window)
        try await driver.wait("native film review persisted", seconds: 60) {
            driver.text("sequence.message", in: window) == "Film review recorded for the current cut."
        }
        let timeline = editor.timeline, resolver = editor.mediaResolver.snapshot()
        let review = try await Task.detached {
            try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: root, timeline: timeline, resolver: resolver)
        }.value
        guard review.durationFrames == frames, review.cutFrames == cuts,
              review.wholePlaybackCompleted, review.adjacentPairCompleted,
              review.findings.count == cuts.count + 1,
              review.findings.first?.evidence == wholeObservation,
              review.findings.allSatisfy({ $0.severity == .info && $0.recommendedAction == .accept && $0.provenance.kind == .nativeUser }),
              Set(review.findings.filter { $0.scope == .adjacentPair }.map(\.startFrame))
                == Set(cuts.map { max(0, $0 - Int(fps.rounded(.up))) }) else {
            throw failed("The saved native review differs from the film, boundary observations or explicit decisions.")
        }
        try driver.capture("review-film-saved", target: window)
        return review
    }

    private static func reviewStyle(context: ProductionPlanningAcceptanceFixture.Context,
                                    driver: ProductionVisualSourcesDriver) async throws -> TimelineStyleReview {
        let editor = context.editor, window = driver.window, root = context.dataRoot
        let timeline = editor.timeline
        guard let snapshot = try await TimelineStyleReview.capture(timeline: timeline, resolver: editor.mediaResolver.snapshot()),
              !snapshot.style.criteria.isEmpty else { throw failed("The film has no required Production Design criteria.") }
        guard (try? TimelineStyleReview.requireCurrent(snapshot)) == nil else { throw failed("The fixture preapproved the timeline style.") }
        try await ProductionV2PlanningAcceptance.selectPhase("production_design", context: context, driver: driver)
        try await driver.click("style.begin", in: window)
        try await driver.wait("unreviewed timeline style is blocked") { driver.state("style.record", in: window) == false }
        var observations: [String: String] = [:]
        for criterion in snapshot.style.criteria {
            guard snapshot.targetsByCriterion[criterion.auditKey]?.isEmpty == false else {
                throw failed("No actual cut evidence supports the style criterion " + criterion.auditKey)
            }
            let observation = "Frames 0–\(timeline.totalFrames): the full played cut uses simplified moving geometric source footage. Its deviation from ‘\(criterion.expected)’ is explicitly accepted for this deterministic fixture."
            observations[criterion.auditKey] = observation
            try await driver.picker("style.choice." + criterion.auditKey, title: "Accept observed deviation",
                expected: "accepted_deviation", in: window)
            try await driver.fill("style.observation." + criterion.auditKey, value: observation, in: window)
            try driver.capture("style-finding-" + criterion.auditKey, target: window)
        }
        try await driver.click("style.record", in: window)
        try await driver.wait("exact timeline style persisted", seconds: 30) {
            driver.text("style.message", in: window) == "Review recorded for this exact cut. Any change to the cut, source media or style requires another review."
        }
        let review = try await Task.detached {
            try TimelineStyleReview.requireCurrent(snapshot)
            return try JSONDecoder().decode(TimelineStyleReview.self,
                from: Data(contentsOf: root.appendingPathComponent(TimelineStyleReview.relativePath)))
        }.value
        guard editor.timeline == timeline, review.fingerprint == snapshot.fingerprint,
              review.findings.count == snapshot.style.criteria.count,
              review.findings.allSatisfy({ $0.acceptedDeviation && !$0.evidenceReferences.isEmpty
                && observations.values.contains($0.observation) }) else {
            throw failed("The native style findings lost their exact cut, image/audio evidence or observations.")
        }
        try driver.record("native timeline style", fields: ["fingerprint": review.fingerprint,
            "criteria": snapshot.style.criteria.map(\.auditKey), "findingCount": review.findings.count])
        return review
    }

    private static func addFinding(start: Int, end: Int, observation: String, driver: ProductionVisualSourcesDriver) async throws {
        try await driver.fill("sequence.start", value: String(start), in: driver.window)
        try await driver.fill("sequence.end", value: String(end), in: driver.window)
        try await driver.fill("sequence.evidence", value: observation, in: driver.window)
        try await driver.click("sequence.add", in: driver.window)
        try await driver.wait("typed film observation added") { driver.text("sequence.evidence", in: driver.window) == "" }
    }

    private static func export(context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver,
                               proof: ProductionPlanAssemblyProofV1, review: ProductionSequenceReviewV2,
                               output: URL) async throws -> [String: Any] {
        let editor = context.editor, window = driver.window, root = context.dataRoot
        guard let owner = editor.openWorkingCopyKey else { throw failed("The export owner closed.") }
        try await driver.click("editor.workspace.export", in: window, enabled: false)
        try await driver.wait("real Export workspace ready") { editor.workspaceFocus == .export && driver.state("export.start", in: window) == true }
        try await driver.picker("export.mode", title: "Video", expected: ExportMode.video.rawValue, in: window)
        try await driver.picker("export.target", title: "Master", expected: DeliveryTargetKindV1.master.rawValue, in: window)
        try await driver.picker("export.codec", title: "H.264", expected: VideoCodec.h264.rawValue, in: window)
        try await driver.picker("export.resolution", title: "720p", expected: ExportResolution.r720p.rawValue, in: window)
        guard driver.state("export.require-sequence", in: window) == true else { throw failed("The V2 export does not require its actual film review.") }
        if editor.activePreviewTab != .timeline {
            try await driver.click("export.artwork.show-film", in: window)
            try await driver.wait("canonical film selected for poster") { editor.activePreviewTab == .timeline }
        }
        let frame = min(max(0, editor.currentFrame), editor.timeline.totalFrames - 1)
        try await driver.click("export.artwork.frame", in: window)
        try await driver.wait("exact film frame selected as poster") {
            driver.text("export.artwork.selection", in: window) == "Film frame \(frame)"
        }
        try driver.capture("export-settings-and-poster", target: window)
        try await driver.click("export.artwork.remove", in: window)
        try await driver.wait("poster removal is effective") { driver.text("export.artwork.selection", in: window) == "none" }
        try await driver.click("export.artwork.frame", in: window)
        try await driver.wait("poster explicitly restored") { driver.text("export.artwork.selection", in: window) == "Film frame \(frame)" }
        let destination = output.appendingPathComponent("owner-v2-film.mp4")
        let prior = Set(ExportQueue.shared.jobs(ownerKey: owner).map(\.id))
        try await driver.click("export.start", in: window)
        try await driver.saveFile(destination, in: window)
        try await driver.wait("native export enqueued", seconds: 30) {
            ExportQueue.shared.jobs(ownerKey: owner).contains { !prior.contains($0.id) }
        }
        let added = ExportQueue.shared.jobs(ownerKey: owner).filter { !prior.contains($0.id) }
        guard added.count == 1, let job = added.first else { throw failed("One native Export action did not produce exactly one queue job.") }
        try await driver.wait("delivery completed", seconds: 120) { job.status.isTerminal }
        guard job.status == .completed, job.canReveal, job.destinationURL?.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() else {
            throw failed(job.failure ?? "The chosen export did not complete.")
        }
        try await driver.click("export.history." + job.id, in: window)
        try await driver.wait("real export QC and poster visible", seconds: 30) {
            driver.text("export.qc", in: window) == "passed"
                && driver.text("export.artwork.verified", in: window)?.count == 64
        }
        let id = job.id
        let evidence = try await Task.detached {
            let attempt = try PipelineDeliveryStore.loadAttempt(id: id, dataRoot: root)
            let artwork = try ExportArtwork.load(spec: attempt.spec, dataRoot: root, timelineSHA256: attempt.finishedTimelineSHA256)
            return (attempt, artwork, try FileDigest.sha256(of: destination),
                try FileDigest.sha256(of: ExportArtwork.outputURL(for: destination)),
                try FileDigest.sha256(of: root.appendingPathComponent(ProductionSequenceReviewV2.relativePath)))
        }.value
        guard evidence.0.status == .succeeded, evidence.0.probeQC?.passed == true,
              (evidence.0.probeQC?.audioChannels ?? 0) > 0,
              evidence.0.sequenceReviewSHA256 == evidence.4, evidence.0.outputSHA256 == evidence.2,
              evidence.0.finishedTimelineSHA256 == review.timeline.sha256,
              let artwork = evidence.1, artwork.selection.source == .filmFrame, artwork.selection.frame == frame,
              artwork.selection.timelineSHA256 == review.timeline.sha256, artwork.pngSHA256 == evidence.3,
              driver.text("export.artwork.verified", in: window) == artwork.pngSHA256,
              driver.text("export.film-binding", in: window) == review.timeline.sha256 else {
            throw failed("Export history, QC, movie, poster and actual reviewed film do not share the same immutable inputs.")
        }
        try await recheck(expected: "passed", driver: driver)
        for (url, label) in [(destination, "movie"), (ExportArtwork.outputURL(for: destination), "poster")] {
            let original = try await Task.detached { try Data(contentsOf: url) }.value
            guard !original.isEmpty else { throw failed("The delivered " + label + " is empty.") }
            var changed = original
            changed[changed.startIndex] ^= 1
            let altered = changed
            try await Task.detached { try altered.write(to: url, options: .atomic) }.value
            do {
                try await recheck(expected: "failed", driver: driver)
                guard driver.text("export.qc.error", in: window)?.isEmpty == false,
                      driver.text("export.qc", in: window) == nil else {
                    throw failed("Changed " + label + " bytes retained a successful output check.")
                }
                try driver.capture("changed-" + label + "-rejected", target: window)
                try await Task.detached { try original.write(to: url, options: .atomic) }.value
                try await recheck(expected: "passed", driver: driver)
            } catch {
                try await Task.detached { try original.write(to: url, options: .atomic) }.value
                throw error
            }
        }
        try driver.record("native delivery byte changes rejected", fields: ["changedMovieRejected": true,
            "changedPosterRejected": true, "exactRestorationReverified": true])
        try await driver.reveal("export.artwork.verified", in: window)
        try driver.capture("export-verified-movie-and-poster", target: window)
        let decoded = try await ProductionV2MovieAcceptance.verify(output: destination, proof: proof,
            review: review, dataRoot: root, timeline: editor.timeline, resolver: editor.mediaResolver.snapshot())
        try PlanningWriterIO.json(evidence.0).write(to: output.appendingPathComponent("owner-v2-delivery.json"), options: .atomic)
        try await Task.detached {
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(evidence.4,
                at: ProductionSequenceReviewV2.relativePath, dataRoot: root))
            try bytes.write(to: output.appendingPathComponent("owner-v2-film-review.json"), options: .atomic)
        }.value
        try driver.record("actual exported movie and poster", fields: ["jobID": id, "outputSHA256": evidence.2,
            "posterSHA256": evidence.3, "timelineSHA256": review.timeline.sha256, "filmReviewSHA256": evidence.4])
        return ["nativeExportWorkspace": true, "nativeSaveDestination": true, "posterSelectedRemovedRestored": true,
            "movieAndPosterPublished": true, "actualOutputQC": true, "changedOutputRejected": true, "movie": destination.lastPathComponent,
            "outputSHA256": evidence.2, "posterSHA256": evidence.3, "decodedMedia": decoded]
    }

    private static func recheck(expected: String, driver: ProductionVisualSourcesDriver) async throws {
        let window = driver.window
        try await driver.wait("current file verification settled") { driver.state("export.qc.verification", in: window) == true }
        guard let value = driver.text("export.qc.verification", in: window),
              let first = value.split(separator: ":").first, let revision = Int(first) else {
            throw failed("The file-verification revision is unavailable.")
        }
        try await driver.click("export.qc.recheck", in: window)
        try await driver.wait("native output recheck " + expected, seconds: 30) {
            driver.state("export.qc.verification", in: window) == true
                && driver.text("export.qc.verification", in: window) == "\(revision + 1):" + expected
        }
        if expected == "passed", driver.text("export.qc", in: window) != "passed" {
            throw failed("The successful file check has no current QC evidence.")
        }
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native V2 film: " + message) }
}
