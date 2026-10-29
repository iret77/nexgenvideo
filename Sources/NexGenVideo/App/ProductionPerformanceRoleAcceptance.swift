import AppKit
import AVFoundation
import NexGenEngine

final class PerformanceSpeechCapture: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var done = false
    private var failure: String?
    private var endBufferReceived = false
    private var utteranceFinished = false

    init(url: URL) { self.url = url; super.init() }

    func append(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !done, failure == nil else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            failure = "The installed voice returned unsupported compressed audio."
            file = nil; done = true
            return
        }
        guard pcm.frameLength > 0 else {
            endBufferReceived = true
            completeIfReady()
            return
        }
        guard !endBufferReceived else { failure = "Speech samples arrived after the end buffer."; file = nil; done = true; return }
        do {
            if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved) }
            try file?.write(from: pcm)
            if let file, Double(file.length) / file.processingFormat.sampleRate > 8 { failure = "The installed voice exceeded the bounded source interval." }
        } catch { failure = error.localizedDescription }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { receivedUtteranceFinish() }
    func receivedUtteranceFinish() { lock.lock(); defer { lock.unlock() }; utteranceFinished = true; completeIfReady() }
    private func completeIfReady() { if endBufferReceived && utteranceFinished { file = nil; done = true } }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish("Speech synthesis was cancelled.") }
    func finish(_ message: String?) { lock.lock(); defer { lock.unlock() }; guard !done else { return }; if let message { failure = message }; file = nil; done = true }
    func status() -> (Bool, String?) { lock.lock(); defer { lock.unlock() }; return (done, failure) }
}

private struct PerformanceVoiceEvidence: Codable, Sendable {
    let identifier: String
    let name: String
    let language: String
    let availableVoiceIDs: [String]
    let utterance: String
    let speechSHA256: String
    let sourceSHA256: String
    let normalizedSpeechSHA256: String
    let sampleRate: Int
    let speechFrames: Int
    let sourceFrames: Int
    let startSeconds: Double
    let endSeconds: Double
    let voiceDownloadRequested: Bool
}

@MainActor
enum ProductionPerformanceRoleAcceptance {
    private static let segmentID = "native-spoken-owner"
    private static let coverageID = "native-spoken-coverage"
    private static let roleID = "spoken-owner"

    static func run(output: URL) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested,
              let binding = PluginLoader.liveBinding(id: "musicvideo"),
              binding.version == HostWorkflowKey.musicvideoV2Version, binding.projectSchema == HostWorkflowKey.musicvideoV2Schema else {
            throw failed("The explicit native case requires the actual Music Video V2 pack.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let voice = try await source(output: output)
        let flow = try await MusicvideoHostFlowAcceptance.start(track: output.appendingPathComponent("role-source.wav"),
            lyrics: nil, binding: binding, evidenceURL: output.appendingPathComponent("startup"))
        defer { flow.close() }
        try await flow.runAnalysis { $0.registerAudioDecoder(AVFoundationAudioDecoder()) }
        let initialRoot = flow.dataRoot
        let sections = try await Task.detached { () throws -> Int in
            guard let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: initialRoot),
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  let sections = value["sections"] as? [[String: Any]], !sections.isEmpty else { throw failed("The actual measured source has no sections.") }
            return sections.count
        }.value
        try await flow.finishPlanningIntake(sectionLabels: (0..<sections).map { "Spoken reference section \($0 + 1)" },
            finalResolution: .res720p, conceptType: .abstract)
        let generation = try ProductionV2GenerationAcceptance()
        defer { generation.close() }
        let editor = flow.editor
        generation.configure(editor: editor)
        let context = ProductionPlanningAcceptanceFixture.Context(document: flow.document, packageURL: flow.projectURL,
            dataRoot: flow.dataRoot, executor: generation.executor(editor: editor))
        guard let window = flow.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window else { throw failed("The actual role project has no document window.") }
        window.setContentSize(AppTheme.Window.projectMin)
        let viewport = try ProductionV2OwnerAcceptance.actualViewport(window)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "performance-roles")
        try await ProductionV2OwnerAcceptance.seedMusicvideoScript(context: context, driver: driver)
        try await driver.click("editor.workspace.production", in: window, enabled: false)
        let movie = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        defer { try? FileManager.default.removeItem(at: movie) }
        _ = try await ProductionV2PlanningAcceptance.run(context: context, sourceVideo: movie, driver: driver, generatedFirstShot: false)
        try await ProductionV2PreRenderAcceptance.references(context: context, driver: driver, requiresNativeLook: false, typedBibleGeneration: generation)
        let base = try await ProductionPlanningAcceptanceFixture.musicvideoPlan(in: context)
        let plan = try await declared(base: base, voice: voice, context: context)
        let negatives = try await refusalCases(plan: plan, context: context)
        let projection = try await ProductionPlanningAcceptanceFixture.promoteImported(in: context, musicvideoPlan: plan)
        try await ProductionV2PlanningAcceptance.selectPhase("shotlist", context: context, driver: driver)
        try await inspect(plan, voice: voice, driver: driver)
        let root = context.dataRoot
        let bound = try await Task.detached { () throws -> (MusicvideoProductionExtensionV2, Data, Data, Data, Data, Data) in
            let value = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: root)
            guard let reference = projection.executionPlan.extensionReferences.first(where: { $0.id == MusicvideoProductionExtensionV2.artifactID }) else {
                throw failed("The canonical plan has no actual Music Video extension reference.")
            }
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root))
            guard let audio = value.performanceSegments.first else { throw failed("The actual phrase export is missing.") }
            let wav = try Data(contentsOf: ProjectLocalFile.requireHash(audio.segmentSHA256, at: audio.segmentPath, dataRoot: root))
            guard value.track.sha256 == voice.sourceSHA256, let receipt = value.performanceReceipts.first else { throw failed("The actual voice source is not bound by the phrase receipt.") }
            let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: root)
            return (value, bytes, wav, try Data(contentsOf: ProjectLocalFile.requireHash(receipt.sha256, at: receipt.path, dataRoot: root)),
                try Data(contentsOf: ProjectLocalFile.requireHash(promotion.projection.sha256, at: promotion.projection.path, dataRoot: root)),
                try Data(contentsOf: ProjectLocalFile.requireHash(value.analysis.sha256, at: value.analysis.path, dataRoot: root)))
        }.value
        let negativeReferences = [projection.draftReference, projection.storyboardReference, bound.0.track, bound.0.analysis, bound.0.treatment]
        guard let extensionReference = projection.executionPlan.extensionReferences.first(where: { $0.id == MusicvideoProductionExtensionV2.artifactID }) else {
            throw failed("The actual role projection has no declared extension output.")
        }
        let negativeOutputPaths = [ProductionPlanProjectionV1.versionPath(projection.header.revision), extensionReference.path]
        for negative in negatives {
            guard let before = negative["before"] as? [String: String],
                  negativeReferences.allSatisfy({ before[$0.path] == $0.sha256 }),
                  negativeOutputPaths.allSatisfy({ before[$0] == nil }) else {
                throw failed("The targeted refusals did not preserve their actual prior inputs and absent output paths.")
            }
        }
        let negativeInputs = try await Task.detached {
            try negativeReferences.enumerated().map { index, reference -> [String: String] in
                let retained = "performance-role-negative-input-\(index).bin"
                let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root))
                try bytes.write(to: output.appendingPathComponent(retained), options: .atomic)
                return ["path": reference.path, "sha256": reference.sha256, "retained": retained]
            }
        }.value
        guard bound.0.performanceSegments.map(\.draft) == plan.performanceSegments, bound.0.finalMix == plan.finalMix,
              bound.0.visualArc == plan.visualArc, bound.0.coverage == plan.coverage else { throw failed("The canonical role plan differs from its declared native inspection.") }
        try bound.1.write(to: output.appendingPathComponent("performance-role-extension.json"))
        try bound.2.write(to: output.appendingPathComponent("performance-role-phrase.wav"))
        try bound.3.write(to: output.appendingPathComponent("performance-role-audio-receipt.json"))
        try bound.4.write(to: output.appendingPathComponent("performance-role-projection.yaml"))
        try bound.5.write(to: output.appendingPathComponent("performance-role-analysis.json"))
        try await ProductionV2PlanningAcceptance.approve("shotlist", artifact: ProductionPlanProjectionV1.versionPath(projection.header.revision), next: "sanity", context: context, driver: driver)
        try await ProductionBibleEntityAcceptance.captureBeforeSave(editor: flow.editor, output: output)
        guard let savedProjectKey = flow.editor.projectId, !savedProjectKey.isEmpty else { throw failed("The role project lost its package identity before Save.") }
        try driver.record("actual technical role project before Save", fields: ["projectKey": savedProjectKey,
            "extensionSHA256": FileDigest.sha256(of: bound.1)])
        try await flow.saveAndReopen(backend: .claudeCode, expectedPhase: "sanity")
        let reopenedRoot = flow.dataRoot
        guard let reopenedWindow = flow.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window else { throw failed("The reopened role project has no window.") }
        guard try ProductionV2OwnerAcceptance.actualViewport(reopenedWindow) == viewport else { throw failed("The actual reopened role viewport or text scale changed.") }
        guard let projectKey = flow.editor.projectId, projectKey == savedProjectKey else { throw failed("Save/reopen changed the role project's package identity.") }
        let reopenedDriver = ProductionVisualSourcesDriver(window: reopenedWindow, output: output, name: "performance-roles-reopened")
        try reopenedDriver.record("actual technical role project reopened", fields: ["projectKey": projectKey,
            "extensionSHA256": FileDigest.sha256(of: bound.1)])
        let reopenedBytes = try await Task.detached { () throws -> Data in
            let current = try ProductionPlanningLineageV2.projection(dataRoot: reopenedRoot)
            let value = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: current, dataRoot: reopenedRoot)
            guard let reference = current.executionPlan.extensionReferences.first(where: { $0.id == MusicvideoProductionExtensionV2.artifactID }),
                  value.performanceSegments.map(\.draft) == plan.performanceSegments else { throw failed("Save/reopen lost the declared role binding.") }
            return try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: reopenedRoot))
        }.value
        guard reopenedBytes == bound.1 else { throw failed("Save/reopen changed the canonical performance extension bytes.") }
        try reopenedBytes.write(to: output.appendingPathComponent("performance-role-extension-reopened.json"))
        let reopenedContext = ProductionPlanningAcceptanceFixture.Context(document: flow.document, packageURL: flow.projectURL,
            dataRoot: reopenedRoot, executor: generation.executor(editor: flow.editor))
        try await reopenedDriver.click("editor.workspace.production", in: reopenedWindow, enabled: false)
        try await ProductionV2PlanningAcceptance.selectPhase("shotlist", context: reopenedContext, driver: reopenedDriver)
        try await inspect(plan, voice: voice, driver: reopenedDriver)
        try await ProductionBibleEntityAcceptance.requireReopened(editor: flow.editor, output: output)
        let result: [String: Any] = ["schema": "nexgenvideo/performance-role-native-evidence/1", "status": "source-only-pending",
            "scope": "technical-dialogue-binding-only", "viewport": viewport, "performedSongClaim": false, "lipQualityClaim": false, "liveProviderClaim": false,
            "voice": try ProductionPlanningAcceptanceFixture.object(voice), "projectKey": projectKey, "projectID": projection.header.projectID, "shotIDs": projection.shots.map(\.id),
            "extensionSHA256": FileDigest.sha256(of: bound.1), "phraseSHA256": FileDigest.sha256(of: bound.2), "negatives": negatives,
            "projectionSHA256": FileDigest.sha256(of: bound.4), "audioReceiptSHA256": FileDigest.sha256(of: bound.3), "analysisSHA256": FileDigest.sha256(of: bound.5),
            "native": driver.result(), "reopenedNative": reopenedDriver.result(), "negativeInputs": negativeInputs,
            "negativeOutputPaths": negativeOutputPaths]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("performance-role-evidence.json"))
        return result
    }

    private static func declared(base: MusicvideoProductionPlanDraftV1, voice: PerformanceVoiceEvidence,
                                 context: ProductionPlanningAcceptanceFixture.Context) async throws -> MusicvideoProductionPlanDraftV1 {
        let root = context.dataRoot
        let voiceID = voice.identifier, start = voice.startSeconds, end = voice.endSeconds
        let performerID = ProductionBibleEntityAcceptance.performerID, segmentID = Self.segmentID, coverageID = Self.coverageID, roleID = Self.roleID
        return try await Task.detached {
            let board = try PlanningWriterIO.storyboard(dataRoot: root)
            guard let track = board.timing.audio?.source else { throw failed("The actual source track is missing.") }
            let audio = try AVAudioFile(forReading: ProjectLocalFile.requireHash(track.sha256, at: track.path, dataRoot: root))
            let rate = Int(audio.processingFormat.sampleRate)
            guard rate == Int(analysisSampleRate), audio.length == Int64(rate * 8) else { throw failed("The exact native PCM source clock changed.") }
            let segment = MusicPerformanceSegmentDraftV1(id: segmentID, shotIDs: board.timing.shots.map(\.id), sourceStartSample: 0,
                sourceEndSample: audio.length, sampleRate: rate, timelineStartSeconds: 0, purpose: .dialogueDiegetic,
                performerIDs: [performerID], audibleVoiceIDs: [voiceID],
                mouthOwnership: [.init(performerID: performerID, voiceID: voiceID,
                    timelineStartSeconds: start, timelineEndSeconds: end)], routeInputRoleID: CoreReferenceInputSlotIDV1.audioTiming,
                phraseBoundaryEvidence: "Actual installed speech PCM, with its known native sample interval, in a bounded synthetic rhythm reference. Technical binding only; no singing or lip-quality claim.")
            let coverage = MusicPerformanceCoverageItemV1(id: coverageID, sectionIDs: base.visualArc.sections.map(\.sectionID), kind: .stagedVocal,
                requiredRoleIDs: [roleID], evidence: [.init(roleID: roleID, shotIDs: board.timing.shots.map(\.id),
                    performerIDs: [performerID], setupIDs: [], showsFullBody: false,
                    showsFloorContact: false, showsHandsAndOrientation: false, minimumContinuousSeconds: 1,
                    assemblyRoleID: "spoken-owner-assembly", referenceDemandIDs: [])], approvedExceptionRoleIDs: [], choreographyBeatIDs: [],
                risk: "The geometric source has no performed mouth.", rescue: "Keep final musical and visible-mouth acceptance pending; this case verifies only declared owner/voice/coverage references.")
            return .init(performanceSegments: [segment], finalMix: base.finalMix, visualArc: base.visualArc, coverage: [coverage])
        }.value
    }

    private static func refusalCases(plan: MusicvideoProductionPlanDraftV1, context: ProductionPlanningAcceptanceFixture.Context) async throws -> [[String: Any]] {
        guard plan.performanceSegments.count == 1, let segment = plan.performanceSegments.first,
              segment.id == segmentID, segment.mouthOwnership.count == 1,
              plan.coverage.count == 1, let coverage = plan.coverage.first, coverage.id == coverageID,
              coverage.requiredRoleIDs == [roleID], coverage.approvedExceptionRoleIDs.isEmpty,
              coverage.evidence.count == 1, coverage.evidence.first?.roleID == roleID else {
            throw failed("The controlled role-negative fixture has no unique declared owner and required coverage role.")
        }
        var evidence: [[String: Any]] = []
        let root = context.dataRoot
        let before = try await Task.detached { try inventory(root) }.value
        for kind in ["foreign-performer", "unowned-voice", "missing-coverage-role"] {
            guard var encoded = try ProductionPlanningAcceptanceFixture.object(plan) as? [String: Any],
                  var coverage = encoded["coverage"] as? [[String: Any]], coverage.count == 1,
                  var segments = encoded["performance_segments"] as? [[String: Any]], segments.count == 1,
                  var owners = segments[0]["mouth_ownership"] as? [[String: Any]], owners.count == 1,
                  var roles = coverage[0]["evidence"] as? [[String: Any]], roles.count == 1 else {
                throw failed("The actual typed role fixture could not be encoded for a targeted negative.")
            }
            if kind == "missing-coverage-role" {
                coverage[0]["evidence"] = []; encoded["coverage"] = coverage
            } else {
                if kind == "foreign-performer" {
                    segments[0]["performer_ids"] = ["missing-native-performer"]; owners[0]["performer_id"] = "missing-native-performer"
                    roles[0]["performer_ids"] = ["missing-native-performer"]; coverage[0]["evidence"] = roles; encoded["coverage"] = coverage
                }
                else { owners[0]["voice_id"] = "missing-native-voice" }
                segments[0]["mouth_ownership"] = owners; encoded["performance_segments"] = segments
            }
            let invalid = try JSONDecoder().decode(MusicvideoProductionPlanDraftV1.self, from: JSONSerialization.data(withJSONObject: encoded))
            let proposal = try ProductionPlanningAcceptanceFixture.productionProposal(in: context, musicvideoPlan: invalid)
            let result = await context.executor.execute(name: "write_shotlist", args: ["origin": "agentProposal", "proposal": try ProductionPlanningAcceptanceFixture.object(proposal)])
            let after = try await Task.detached { try inventory(root) }.value
            guard result.isError, after == before else { throw failed("An invalid declared role changed canonical project bytes: " + kind) }
            let message = result.content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined(separator: "\n")
            let expected: String
            switch kind {
            case "foreign-performer": expected = ProductionPlanningError.invalid("musicvideo.performer").localizedDescription
            case "unowned-voice": expected = MusicvideoProductionValidationErrorV1.mouthOwnershipMismatch(segmentID).localizedDescription
            default: expected = MusicvideoProductionValidationErrorV1.coverageMissing(coverageID).localizedDescription
            }
            guard message.contains(expected) else { throw failed("The declared role fault was refused for an unrelated reason: " + kind + ": " + message) }
            evidence.append(["case": kind, "proposal": encoded, "before": before, "after": after, "error": message, "expectedError": expected,
                "reason": kind == "foreign-performer" ? "musicvideo.performer" : (kind == "unowned-voice" ? "mouthOwnershipMismatch" : "coverageMissing")])
        }
        return evidence
    }

    private static func inspect(_ plan: MusicvideoProductionPlanDraftV1, voice: PerformanceVoiceEvidence, driver: ProductionVisualSourcesDriver) async throws {
        guard plan.performanceSegments.count == 1, let segment = plan.performanceSegments.first,
              segment.id == segmentID, segment.mouthOwnership.count == 1 else { throw failed("The actual role inspection has no unique declared segment and mouth owner.") }
        let window = driver.window
        let voiceID = voice.identifier
        let performer = "production.musicvideo.performers." + segmentID
        try await driver.wait("canonical music plan loaded") { driver.state("production.musicvideo.review", in: window) == true }
        try await ProductionNativeDisclosureAcceptance.toggle("production.musicvideo.performance.open", content: performer, expanded: true, driver: driver, in: window)
        try await ProductionNativeReadingAcceptance.read(performer, expected: "Reference performer", driver: driver)
        try await ProductionNativeReadingAcceptance.read("production.musicvideo.voices." + segmentID,
            expected: voiceID, driver: driver)
        try await ProductionNativeReadingAcceptance.read("production.musicvideo.purpose." + segmentID,
            expected: "Shot 1, Shot 2 · Dialogue / scene audio", driver: driver)
        let mouth = "production.musicvideo.mouth." + segmentID + ".0"
        let owner = segment.mouthOwnership[0]
        let expectedMouth = "Reference performer → " + voiceID
            + " · " + String(format: "%.3f–%.3f s", owner.timelineStartSeconds, owner.timelineEndSeconds)
        try await ProductionNativeReadingAcceptance.read(mouth, expected: expectedMouth, driver: driver)
        let coverage = "production.musicvideo.coverage." + coverageID + "." + roleID
        try await ProductionNativeDisclosureAcceptance.toggle("production.musicvideo.coverage.open", content: coverage, expanded: true, driver: driver, in: window)
        let expectedCoverage = "Shot 1, Shot 2 · at least 1.000 s continuously"
        try await ProductionNativeReadingAcceptance.read(coverage, expected: expectedCoverage, driver: driver)
        try driver.capture("role-and-coverage-visible", target: window)
        try driver.record("native technical role bindings inspected", fields: ["segmentID": segmentID,
            "performerIDs": segment.performerIDs, "audibleVoiceIDs": segment.audibleVoiceIDs,
            "mouthText": expectedMouth, "coverageText": expectedCoverage, "performedSongClaim": false])
    }

    private static func source(output: URL) async throws -> PerformanceVoiceEvidence {
        let available = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") && $0.quality == .default
            && !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice) }.sorted { $0.identifier < $1.identifier }
        guard let voice = available.first else { throw failed("No installed English speech voice is available. This case does not download a voice.") }
        let raw = output.appendingPathComponent("role-speech.wav")
        let capture = PerformanceSpeechCapture(url: raw), synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = capture
        let utterance = AVSpeechUtterance(string: "This voice owns this spoken phrase.")
        utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.write(utterance) { capture.append($0) }
        defer { synthesizer.stopSpeaking(at: .immediate); capture.finish(nil) }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while true {
            let current = capture.status()
            if let failure = current.1 { throw failed(failure) }
            if current.0 { break }
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw failed("The installed voice did not finish producing actual PCM within 30 seconds.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let failure = capture.status().1 { throw failed(failure) }
        let identity = voice.identifier, language = voice.language, name = voice.name, availableIDs = available.map(\.identifier)
        return try await Task.detached {
            let pcm = try AVFoundationAudioDecoder().decode(raw), rate = pcm.sampleRate
            guard rate == analysisSampleRate, pcm.samples.count > Int(rate), pcm.samples.count < Int(rate * 6),
                  pcm.samples.contains(where: { abs($0) > 0.01 }),
                  let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 8)),
                  let channel = buffer.floatChannelData?[0] else { throw failed("The actual installed voice did not produce bounded non-silent PCM.") }
            buffer.frameLength = buffer.frameCapacity
            let offset = Int(rate / 2)
            for i in 0..<Int(buffer.frameLength) {
                let t = Double(i) / rate, beat = t.truncatingRemainder(dividingBy: 0.5)
                let carrier = Float(0.01 * sin(2 * .pi * 173 * t) + (beat < 0.04 ? 0.5 * exp(-40 * beat) * sin(2 * .pi * 1000 * beat) : 0))
                let sample = i >= offset && i - offset < pcm.samples.count ? pcm.samples[i - offset] * 0.6 : 0
                channel[i] = max(-1, min(1, carrier + sample))
            }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let normalized = output.appendingPathComponent("role-speech-analysis.wav")
            guard let speech = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.samples.count)),
                  let samples = speech.floatChannelData?[0] else { throw failed("The normalized speech buffer could not be allocated.") }
            speech.frameLength = speech.frameCapacity
            for i in pcm.samples.indices { samples[i] = pcm.samples[i] }
            do { let file = try AVAudioFile(forWriting: normalized, settings: settings); try file.write(from: speech) }
            let target = output.appendingPathComponent("role-source.wav")
            do { let file = try AVAudioFile(forWriting: target, settings: settings); try file.write(from: buffer) }
            let metadata = PerformanceVoiceEvidence(identifier: identity, name: name, language: language, availableVoiceIDs: availableIDs,
                utterance: "This voice owns this spoken phrase.", speechSHA256: try FileDigest.sha256(of: raw),
                sourceSHA256: try FileDigest.sha256(of: target), normalizedSpeechSHA256: try FileDigest.sha256(of: normalized), sampleRate: Int(rate), speechFrames: pcm.samples.count,
                sourceFrames: Int(buffer.frameLength), startSeconds: Double(offset) / rate,
                endSeconds: Double(offset + pcm.samples.count) / rate, voiceDownloadRequested: false)
            try JSONEncoder().encode(metadata).write(to: output.appendingPathComponent("performance-role-voice.json"))
            return metadata
        }.value
    }

    nonisolated private static func inventory(_ root: URL) throws -> [String: String] {
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        var result: [String: String] = [:]
        while let url = urls?.nextObject() as? URL {
            try Task.checkCancellation()
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = FrameInventory.relativePath(of: url, to: root)
            result[path] = try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: root))
        }
        return result
    }

    nonisolated private static func failed(_ value: String) -> GateBlocked { GateBlocked("Technical performer/voice acceptance: " + value) }
}
