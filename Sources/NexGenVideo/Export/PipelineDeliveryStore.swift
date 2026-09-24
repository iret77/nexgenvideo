import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import NexGenEngine

enum PipelineDeliveryStore {
    struct FinishedState: Sendable {
        let plan: FinishPlanV1
        let planData: Data
        let manifest: FinishedTimelineManifestV1
        let manifestData: Data
    }

    struct OutputEvidence {
        let sha256: String
        let byteCount: Int64
        let probeQC: DeliveryProbeQCV1
    }

    struct FinishResult {
        let attempt: DeliveryAttemptV1
        let selectionWarning: String?
    }

    private struct AdoptionPreparation: Sendable {
        let metadata: ProjectMeta
        let timelineData: Data
        let timelineSHA256: String
        let timelinePath: String
        let plan: FinishPlanV1
        let planData: Data
        let media: [RenderPublishedArtifactV1]
        let assemblyIsCurrent: Bool
    }

    static let selectionPath = "delivery/selection.v1.json"
    private static let attemptsDirectory = "delivery/attempts"
    private static let jobsDirectory = "delivery/jobs"
    private static let timelinesDirectory = "delivery/timelines"

    @MainActor
    static func adoptCurrentTimeline(
        editor: EditorViewModel,
        requireSequenceReview: Bool
    ) async throws -> FinishedState {
        guard let home = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: home),
              let workingCopyKey = editor.openWorkingCopyKey else {
            throw ToolError("Open a project before preparing delivery.")
        }
        let boundTimeline = editor.timeline
        let boundManifest = editor.mediaManifest
        let boundResolver = editor.mediaResolver.snapshot()
        let cancellationFlag = ExportCancellationFlag()
        let prepared = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try prepareAdoption(
                    dataRoot: dataRoot,
                    timeline: boundTimeline,
                    resolver: boundResolver,
                    requireSequenceReview: requireSequenceReview,
                    isCancelled: { cancellationFlag.isCancelled }
                )
            }.value
        } onCancel: {
            cancellationFlag.cancel()
        }
        guard editor.openWorkingCopyKey == workingCopyKey,
              editor.workingRoot?.standardizedFileURL == home.standardizedFileURL,
              editor.mediaManifest == boundManifest,
              FileDigest.sha256(
                  of: try PipelineAssemblyStore.canonical(editor.timeline)
              ) == prepared.timelineSHA256,
              try YAMLArtifactStore(dataRoot: dataRoot).load(
                  ProjectMeta.self,
                  at: PipelineLayout.projectFile
              ) == prepared.metadata else {
            throw CancellationError()
        }
        let manifest = FinishedTimelineManifestV1(
            projectID: prepared.metadata.project,
            finishPlanSHA256: FileDigest.sha256(of: prepared.planData),
            timelinePath: prepared.timelinePath,
            timelineSHA256: prepared.timelineSHA256,
            media: prepared.media,
            operationProofs: [],
            adoptedManualTimeline: !prepared.assemblyIsCurrent
        )
        try DeliveryValidatorV1.validate(
            manifest: manifest,
            plan: prepared.plan,
            planSHA256: FileDigest.sha256(of: prepared.planData),
            currentTimelineSHA256: prepared.timelineSHA256
        )
        let manifestData = try PipelineAssemblyStore.canonical(manifest)
        let timelineURL = dataRoot.appendingPathComponent(prepared.timelinePath)
        let planURL = dataRoot.appendingPathComponent(FinishPlanV1.relativePath)
        let manifestURL = dataRoot.appendingPathComponent(FinishedTimelineManifestV1.relativePath)
        try ProjectWorkingCopy.markDirty(key: workingCopyKey)
        try ArtifactTransaction.perform(
            paths: [timelineURL, planURL, manifestURL],
            dataRoot: dataRoot
        ) {
            try FileManager.default.createDirectory(
                at: timelineURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: timelineURL.path) {
                guard try Data(contentsOf: timelineURL) == prepared.timelineData else {
                    throw ToolError("An immutable finished timeline has different bytes.")
                }
            } else {
                try prepared.timelineData.write(to: timelineURL, options: .atomic)
            }
            try prepared.planData.write(to: planURL, options: .atomic)
            try manifestData.write(to: manifestURL, options: .atomic)
        }
        editor.onPipelineChanged?()
        return .init(
            plan: prepared.plan,
            planData: prepared.planData,
            manifest: manifest,
            manifestData: manifestData
        )
    }

    static func requireCurrentFinished(
        dataRoot: URL,
        timeline: Timeline,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> FinishedState {
        if isCancelled() { throw CancellationError() }
        let planData = try Data(contentsOf: ProjectLocalFile.resolve(
            FinishPlanV1.relativePath,
            dataRoot: dataRoot
        ))
        let manifestData = try Data(contentsOf: ProjectLocalFile.resolve(
            FinishedTimelineManifestV1.relativePath,
            dataRoot: dataRoot
        ))
        let plan = try JSONDecoder().decode(FinishPlanV1.self, from: planData)
        let manifest = try JSONDecoder().decode(
            FinishedTimelineManifestV1.self,
            from: manifestData
        )
        let timelineData = try PipelineAssemblyStore.canonical(timeline)
        let timelineSHA256 = FileDigest.sha256(of: timelineData)
        try DeliveryValidatorV1.validate(
            manifest: manifest,
            plan: plan,
            planSHA256: FileDigest.sha256(of: planData),
            currentTimelineSHA256: timelineSHA256
        )
        let frozenTimeline = try requireCancellableHash(
            manifest.timelineSHA256,
            at: manifest.timelinePath,
            dataRoot: dataRoot,
            isCancelled: isCancelled
        )
        guard try Data(contentsOf: frozenTimeline) == timelineData else {
            throw ToolError("The finished timeline snapshot is stale.")
        }
        for item in manifest.media {
            if isCancelled() { throw CancellationError() }
            let url = try boundURL(item.path, dataRoot: dataRoot)
            guard try cancellableSHA256(of: url, isCancelled: isCancelled) == item.sha256 else {
                throw ToolError("Finished media changed or is offline: \(item.path)")
            }
        }
        for operation in plan.operations {
            if isCancelled() { throw CancellationError() }
            _ = try requireCancellableHash(
                operation.settingsSHA256,
                at: operation.settingsPath,
                dataRoot: dataRoot,
                isCancelled: isCancelled
            )
            _ = try requireCancellableHash(
                operation.outputSHA256,
                at: operation.outputPath,
                dataRoot: dataRoot,
                isCancelled: isCancelled
            )
        }
        if let expectedAssembly = plan.assemblyManifestSHA256 {
            if isCancelled() { throw CancellationError() }
            let currentAssembly = try requireCancellableHash(
                expectedAssembly,
                at: AssemblyManifestV1.relativePath,
                dataRoot: dataRoot,
                isCancelled: isCancelled
            )
            _ = currentAssembly
            guard let assembly = try PipelineAssemblyStore.load(dataRoot: dataRoot),
                  assembly.manifest.timelineFingerprint == timelineSHA256 else {
                throw ToolError("The bound assembly is no longer the current cut.")
            }
        }
        if let expectedReview = plan.sequenceReviewSHA256 {
            if isCancelled() { throw CancellationError() }
            _ = try requireCancellableHash(
                expectedReview,
                at: SequenceReviewV1.relativePath,
                dataRoot: dataRoot,
                isCancelled: isCancelled
            )
            _ = try PipelineSequenceReviewStore.requireCurrent(
                dataRoot: dataRoot,
                timeline: timeline
            )
            if isCancelled() { throw CancellationError() }
        }
        return .init(
            plan: plan,
            planData: planData,
            manifest: manifest,
            manifestData: manifestData
        )
    }

    @MainActor
    static func defaultSpec(
        id: String,
        targetKind: DeliveryTargetKindV1,
        timeline: Timeline,
        format: ExportFormat,
        resolution: ExportResolution,
        requireSequenceReview: Bool,
        extensionRefs: [String] = []
    ) throws -> DeliverySpecV1 {
        guard format != .xml, format != .fcpxml else {
            throw ToolError("Delivery video needs a video codec.")
        }
        let outputSize = resolution.renderSize(for: CGSize(
            width: timeline.width,
            height: timeline.height
        ))
        let hasAudio = timeline.tracks.contains {
            $0.type == .audio && !$0.muted && !$0.clips.isEmpty
        }
        let spec = DeliverySpecV1(
            id: id,
            targetKind: targetKind,
            container: format == .prores ? "mov" : "mp4",
            videoCodec: codecID(format),
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            fpsNumerator: timeline.fps,
            colorSpace: "rec709-sdr",
            hdr: false,
            audioLayout: hasAudio ? "present" : "none",
            captionMode: TextLayerController.hasVisibleText(in: timeline)
                ? "burned-in" : "none",
            disclosureMode: "project-record",
            requirements: [
                .init(
                    id: "core.sequence-review",
                    state: .enforced,
                    required: requireSequenceReview,
                    value: requireSequenceReview ? "current" : "optional"
                ),
                .init(
                    id: "core.offline-media",
                    state: .enforced,
                    required: true,
                    value: "reject"
                ),
            ],
            extensionRefs: extensionRefs
        )
        try validateSupportedSpec(spec)
        return spec
    }

    static func requireBoundFinished(
        dataRoot: URL,
        finished: FinishedState,
        timeline: Timeline,
        resolver: MediaResolver,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws {
        if isCancelled() { throw CancellationError() }
        let timelineData = try PipelineAssemblyStore.canonical(timeline)
        let timelineSHA256 = FileDigest.sha256(of: timelineData)
        try DeliveryValidatorV1.validate(
            manifest: finished.manifest,
            plan: finished.plan,
            planSHA256: FileDigest.sha256(of: finished.planData),
            currentTimelineSHA256: timelineSHA256
        )
        guard finished.manifestData == (try PipelineAssemblyStore.canonical(finished.manifest)),
              finished.planData == (try PipelineAssemblyStore.canonical(finished.plan)) else {
            throw ToolError("The bound delivery evidence is not canonical.")
        }
        let frozenTimeline = try requireCancellableHash(
            finished.manifest.timelineSHA256,
            at: finished.manifest.timelinePath,
            dataRoot: dataRoot,
            isCancelled: isCancelled
        )
        guard try Data(contentsOf: frozenTimeline) == timelineData else {
            throw ToolError("The bound finished timeline snapshot changed.")
        }
        let mediaProofs = try currentMediaProofs(
            timeline: timeline,
            resolver: resolver,
            isCancelled: isCancelled
        )
        guard mediaProofs == finished.manifest.media else {
            throw ToolError("The bound delivery media changed or was substituted.")
        }
        for operation in finished.plan.operations {
            if isCancelled() { throw CancellationError() }
            _ = try requireCancellableHash(
                operation.settingsSHA256,
                at: operation.settingsPath,
                dataRoot: dataRoot,
                isCancelled: isCancelled
            )
            _ = try requireCancellableHash(
                operation.outputSHA256,
                at: operation.outputPath,
                dataRoot: dataRoot,
                isCancelled: isCancelled
            )
        }
        if let assemblySHA256 = finished.plan.assemblyManifestSHA256 {
            if isCancelled() { throw CancellationError() }
            _ = try requireCancellableHash(
                assemblySHA256,
                at: AssemblyManifestV1.relativePath,
                dataRoot: dataRoot,
                isCancelled: isCancelled
            )
        }
        if let sequenceReviewSHA256 = finished.plan.sequenceReviewSHA256 {
            if isCancelled() { throw CancellationError() }
            _ = try requireCancellableHash(
                sequenceReviewSHA256,
                at: SequenceReviewV1.relativePath,
                dataRoot: dataRoot,
                isCancelled: isCancelled
            )
        }
    }

    static func extensionFiles(
        for spec: DeliverySpecV1,
        dataRoot: URL
    ) throws -> [(path: String, url: URL)] {
        try validateSupportedSpec(spec)
        return try spec.extensionRefs.map { path in
            let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw ToolError("A required delivery extension is missing: \(path)")
            }
            return (path, url)
        }
    }

    static func enqueueAttempt(
        id: String,
        dataRoot: URL,
        finished: FinishedState,
        spec: DeliverySpecV1,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL,
        timeline: Timeline,
        resolver: MediaResolver,
        bindingAlreadyValidated: Bool = false
    ) throws -> DeliveryAttemptV1 {
        try safeID(id)
        let currentURL = dataRoot.appendingPathComponent(
            "\(jobsDirectory)/\(id)/current.v1.json"
        )
        let attemptURL = dataRoot.appendingPathComponent(
            "\(attemptsDirectory)/\(id).v1.json"
        )
        guard !FileManager.default.fileExists(atPath: currentURL.path),
              !FileManager.default.fileExists(atPath: attemptURL.path) else {
            throw ToolError("A delivery job with this ID already exists in project history.")
        }
        try validateSupportedSpec(spec)
        guard outputURL.pathExtension.lowercased() == spec.container else {
            throw ToolError("The delivery filename extension does not match the delivery container.")
        }
        _ = try extensionFiles(for: spec, dataRoot: dataRoot)
        let outputSize = resolution.renderSize(for: CGSize(
            width: timeline.width,
            height: timeline.height
        ))
        guard spec.videoCodec == codecID(format),
              spec.container == (format == .prores ? "mov" : "mp4"),
              spec.width == Int(outputSize.width),
              spec.height == Int(outputSize.height),
              spec.fpsNumerator == timeline.fps,
              spec.fpsDenominator == 1 else {
            throw ToolError("The delivery spec does not match the bound timeline.")
        }
        if !bindingAlreadyValidated {
            try requireBoundFinished(
                dataRoot: dataRoot,
                finished: finished,
                timeline: timeline,
                resolver: resolver
            )
        }
        let requiresReview = spec.requirements.contains {
            $0.id == "core.sequence-review" && $0.required
        }
        guard !requiresReview || finished.plan.sequenceReviewSHA256 != nil else {
            throw ToolError("This delivery spec requires a current sequence review.")
        }
        let attempt = DeliveryAttemptV1(
            id: id,
            spec: spec,
            finishedTimelineSHA256: finished.manifest.timelineSHA256,
            sequenceReviewSHA256: finished.plan.sequenceReviewSHA256,
            status: .queued,
            outputPath: outputURL.path,
            createdAt: currentTimestamp()
        )
        try record(attempt, dataRoot: dataRoot, terminal: false)
        return attempt
    }

    static func markRunning(
        _ attempt: DeliveryAttemptV1,
        dataRoot: URL
    ) throws -> DeliveryAttemptV1 {
        let running = copy(attempt, status: .running)
        try record(running, dataRoot: dataRoot, terminal: false)
        return running
    }

    static func finishUnsuccessful(
        _ attempt: DeliveryAttemptV1,
        status: DeliveryJobStatusV1,
        reason: String,
        dataRoot: URL
    ) throws -> DeliveryAttemptV1 {
        guard [.failed, .cancelled, .interrupted].contains(status) else {
            throw ToolError("Invalid unsuccessful delivery status.")
        }
        let terminal = copy(
            attempt,
            status: status,
            failures: [reason],
            completedAt: currentTimestamp()
        )
        try record(terminal, dataRoot: dataRoot, terminal: true)
        return terminal
    }

    static func finishSuccessful(
        _ attempt: DeliveryAttemptV1,
        dataRoot: URL,
        finished: FinishedState,
        outputURL: URL,
        evidence: OutputEvidence,
        publishedState: ExportQueue.PathState,
        selectIfCurrent: Bool
    ) throws -> FinishResult {
        guard case .file(let sha256, let byteCount) = publishedState,
              sha256 == evidence.sha256 else {
            throw ToolError("The published delivery bytes do not match the verified export.")
        }
        guard byteCount == Int(evidence.byteCount) else {
            throw ToolError("The published delivery size changed before its receipt was recorded.")
        }
        let succeeded = copy(
            attempt,
            status: .succeeded,
            outputPath: outputURL.path,
            outputSHA256: evidence.sha256,
            outputByteCount: evidence.byteCount,
            probeQC: evidence.probeQC,
            completedAt: currentTimestamp()
        )
        try DeliveryValidatorV1.validateSuccessfulAttempt(
            succeeded,
            finishedTimelineSHA256: finished.manifest.timelineSHA256,
            requiredSequenceReviewSHA256: finished.plan.sequenceReviewSHA256
        )
        try record(succeeded, dataRoot: dataRoot, terminal: true)
        var selectionWarning: String?
        if selectIfCurrent && isCurrent(finished, dataRoot: dataRoot) {
            do {
                try select(succeeded, dataRoot: dataRoot)
            } catch {
                selectionWarning = "Delivery completed, but its current selection could not be updated: \(error.localizedDescription)"
            }
        }
        return .init(attempt: succeeded, selectionWarning: selectionWarning)
    }

    static func inspectSuccessfulOutput(
        outputURL: URL,
        spec: DeliverySpecV1,
        expectedDurationFrames: Int,
        isCancelled: @Sendable () -> Bool = { false }
    ) async throws -> OutputEvidence {
        let qc = try await probeOutput(
            outputURL: outputURL,
            spec: spec,
            expectedDurationFrames: expectedDurationFrames,
            isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }
        guard qc.passed else {
            throw ToolError("The exported bytes do not match the delivery spec.")
        }
        let values = try outputURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0 else {
            throw ToolError("The exported delivery is missing or empty.")
        }
        return OutputEvidence(
            sha256: try cancellableSHA256(of: outputURL, isCancelled: isCancelled),
            byteCount: Int64(size),
            probeQC: qc
        )
    }

    static func listAttempts(dataRoot: URL) throws -> [DeliveryAttemptV1] {
        let root = dataRoot.appendingPathComponent(attemptsDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard root.resolvingSymlinksInPath()
                == dataRoot.resolvingSymlinksInPath().appendingPathComponent(attemptsDirectory) else {
            throw ToolError("Delivery attempts cannot traverse symbolic links.")
        }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { $0.pathExtension == "json" }.map { url in
            let value = try JSONDecoder().decode(
                DeliveryAttemptV1.self,
                from: Data(contentsOf: url)
            )
            try DeliveryValidatorV1.validate(attempt: value)
            return value
        }.sorted { $0.createdAt > $1.createdAt }
    }

    @MainActor
    static func export(
        editor: EditorViewModel,
        spec: DeliverySpecV1,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL,
        service: ExportService
    ) async throws -> DeliveryAttemptV1 {
        guard let home = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: home),
              let ownerKey = editor.openWorkingCopyKey else {
            throw ToolError("Open a project before exporting a delivery.")
        }
        let job = try await ExportQueue.shared.enqueueDelivery(
            editor: editor,
            spec: spec,
            format: format,
            resolution: resolution,
            outputURL: outputURL
        )
        let completed = await withTaskCancellationHandler {
            await ExportQueue.shared.waitForCompletion(jobID: job.id)
        } onCancel: {
            Task { @MainActor in ExportQueue.shared.cancel(jobID: job.id) }
        }
        guard let completed, completed.status == .completed else {
            let reason = completed?.failure ?? "Export did not complete."
            service.error = reason
            throw ToolError(reason)
        }
        service.progress = 1
        let jobID = job.id
        let cancellationFlag = ExportCancellationFlag()
        let attempt = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try loadAttempt(
                    id: jobID,
                    dataRoot: dataRoot,
                    isCancelled: { cancellationFlag.isCancelled }
                )
            }.value
        } onCancel: {
            cancellationFlag.cancel()
        }
        guard editor.openWorkingCopyKey == ownerKey,
              editor.workingRoot?.standardizedFileURL == home.standardizedFileURL else {
            throw CancellationError()
        }
        return attempt
    }

    @discardableResult
    static func recoverInterruptedJobs(
        dataRoot: URL,
        excludingIDs: Set<String> = [],
        willMutate: (() throws -> Void)? = nil,
        didRecover: ((DeliveryAttemptV1) -> Void)? = nil
    ) throws -> Bool {
        let root = dataRoot.appendingPathComponent(jobsDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        guard root.resolvingSymlinksInPath()
                == dataRoot.resolvingSymlinksInPath().appendingPathComponent(jobsDirectory) else {
            throw ToolError("Delivery jobs cannot traverse symbolic links.")
        }
        var recovered = false
        for directory in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) where (try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true) {
            let currentURL = directory.appendingPathComponent("current.v1.json")
            guard FileManager.default.fileExists(atPath: currentURL.path) else { continue }
            let value = try JSONDecoder().decode(
                DeliveryAttemptV1.self,
                from: Data(contentsOf: currentURL)
            )
            guard !excludingIDs.contains(value.id) else { continue }
            guard [.queued, .running].contains(value.status) else { continue }
            if !recovered { try willMutate?() }
            let interrupted = copy(
                value,
                status: .interrupted,
                failures: value.failures + ["Export interrupted before completion."],
                completedAt: currentTimestamp()
            )
            try record(interrupted, dataRoot: dataRoot, terminal: true)
            didRecover?(interrupted)
            recovered = true
        }
        return recovered
    }

    static func loadAttempt(
        id: String,
        dataRoot: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> DeliveryAttemptV1 {
        if isCancelled() { throw CancellationError() }
        try safeID(id)
        let path = "\(attemptsDirectory)/\(id).v1.json"
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
        let value = try JSONDecoder().decode(DeliveryAttemptV1.self, from: bytes)
        try DeliveryValidatorV1.validate(attempt: value)
        guard value.id == id,
              ![.queued, .running].contains(value.status) else {
            throw ToolError("Delivery attempt history is malformed.")
        }
        if value.status == .succeeded {
            let output = try boundURL(value.outputPath ?? "", dataRoot: dataRoot)
            guard try cancellableSHA256(
                of: output,
                isCancelled: isCancelled
            ) == value.outputSHA256 else {
                throw ToolError("The selected delivery output bytes changed.")
            }
        }
        return value
    }

    private static func prepareAdoption(
        dataRoot: URL,
        timeline: Timeline,
        resolver: MediaResolver,
        requireSequenceReview: Bool,
        isCancelled: @Sendable () -> Bool
    ) throws -> AdoptionPreparation {
        if isCancelled() { throw CancellationError() }
        guard timeline.totalFrames > 0,
              timeline.tracks.contains(where: {
                  $0.type == .video && !$0.hidden && !$0.clips.isEmpty
              }) else {
            throw ToolError("Add visible video to the timeline before preparing delivery.")
        }
        let metadata = try YAMLArtifactStore(dataRoot: dataRoot).load(
            ProjectMeta.self,
            at: PipelineLayout.projectFile
        )
        let timelineData = try PipelineAssemblyStore.canonical(timeline)
        let timelineSHA256 = FileDigest.sha256(of: timelineData)
        let timelinePath = "\(timelinesDirectory)/\(timelineSHA256).json"

        let assembly = try PipelineAssemblyStore.load(dataRoot: dataRoot)
        let assemblyIsCurrent = assembly.map {
            $0.manifest.timelineFingerprint == timelineSHA256
        } ?? false
        let assemblyManifestSHA256: String? = if assemblyIsCurrent {
            try cancellableSHA256(
                of: ProjectLocalFile.resolve(
                    AssemblyManifestV1.relativePath,
                    dataRoot: dataRoot
                ),
                isCancelled: isCancelled
            )
        } else {
            nil
        }

        let sequenceReviewSHA256: String?
        do {
            if isCancelled() { throw CancellationError() }
            _ = try PipelineSequenceReviewStore.requireCurrent(
                dataRoot: dataRoot,
                timeline: timeline
            )
            if isCancelled() { throw CancellationError() }
            sequenceReviewSHA256 = try cancellableSHA256(
                of: ProjectLocalFile.resolve(
                    SequenceReviewV1.relativePath,
                    dataRoot: dataRoot
                ),
                isCancelled: isCancelled
            )
        } catch {
            if isCancelled() { throw CancellationError() }
            if requireSequenceReview {
                throw ToolError("Record a current sequence review without blocking findings before preparing this delivery.")
            }
            sequenceReviewSHA256 = nil
        }

        let plan = FinishPlanV1(
            projectID: metadata.project,
            sourceTimelineSHA256: timelineSHA256,
            assemblyManifestSHA256: assemblyManifestSHA256,
            sequenceReviewSHA256: sequenceReviewSHA256,
            operations: []
        )
        try DeliveryValidatorV1.validate(plan: plan)
        let planData = try PipelineAssemblyStore.canonical(plan)
        let media = try currentMediaProofs(
            timeline: timeline,
            resolver: resolver,
            isCancelled: isCancelled
        )
        return .init(
            metadata: metadata,
            timelineData: timelineData,
            timelineSHA256: timelineSHA256,
            timelinePath: timelinePath,
            plan: plan,
            planData: planData,
            media: media,
            assemblyIsCurrent: assemblyIsCurrent
        )
    }

    private static func currentMediaProofs(
        timeline: Timeline,
        resolver: MediaResolver,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> [RenderPublishedArtifactV1] {
        let refs = Set(timeline.tracks.filter { track in
            !track.hidden && (track.type != .audio || !track.muted)
        }.flatMap { track in
            track.clips.compactMap { clip in
                clip.sourceClipType == .text ? nil : clip.mediaRef
            }
        }).sorted()
        return try refs.map { ref in
            if isCancelled() { throw CancellationError() }
            guard let url = resolver.resolveURL(for: ref) else {
                throw ToolError("Delivery media is offline: \(resolver.displayName(for: ref))")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, values.fileSize.map({ $0 > 0 }) == true else {
                throw ToolError("Delivery media is unreadable: \(resolver.displayName(for: ref))")
            }
            let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
            return .init(
                path: resolvedURL.path,
                sha256: try cancellableSHA256(
                    of: resolvedURL,
                    isCancelled: isCancelled
                )
            )
        }
    }

    private static func validateSupportedSpec(_ spec: DeliverySpecV1) throws {
        try DeliveryValidatorV1.validate(spec: spec)
        guard ["mp4", "mov"].contains(spec.container),
              ["avc1", "hvc1", "apcn"].contains(spec.videoCodec),
              spec.colorSpace == "rec709-sdr",
              !spec.hdr,
              ["present", "none"].contains(spec.audioLayout),
              ["burned-in", "none"].contains(spec.captionMode),
              spec.disclosureMode == "project-record",
              spec.loudnessTarget == nil else {
            throw ToolError("The requested delivery setting is not implemented by the current exporter.")
        }
        for path in spec.extensionRefs {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else {
                throw ToolError("Delivery extension references must be safe project-local paths.")
            }
        }
    }

    static func probeOutput(
        outputURL: URL,
        spec: DeliverySpecV1,
        expectedDurationFrames: Int,
        isCancelled: @Sendable () -> Bool = { false }
    ) async throws -> DeliveryProbeQCV1 {
        if isCancelled() { throw CancellationError() }
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        if isCancelled() { throw CancellationError() }
        guard duration.isNumeric,
              let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let videoDescription = try await videoTrack.load(.formatDescriptions).first else {
            throw ToolError("The exported delivery has no playable video track.")
        }
        if isCancelled() { throw CancellationError() }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let encodedSize = naturalSize.applying(transform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let actualCodec = fourCC(CMFormatDescriptionGetMediaSubType(videoDescription))
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if isCancelled() { throw CancellationError() }
        var audioCodec: String?
        var audioChannels = 0
        if let audioTrack = audioTracks.first,
           let description = try await audioTrack.load(.formatDescriptions).first {
            audioCodec = fourCC(CMFormatDescriptionGetMediaSubType(description))
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                audioChannels = Int(basic.pointee.mChannelsPerFrame)
            }
        }
        if isCancelled() { throw CancellationError() }
        let expectedDuration = Double(expectedDurationFrames)
            / Double(spec.fpsNumerator) * Double(spec.fpsDenominator)
        let frameTolerance = Double(spec.fpsDenominator) / Double(spec.fpsNumerator)
        let audioMatches = spec.audioLayout == "none"
            ? audioTracks.isEmpty
            : !audioTracks.isEmpty && audioChannels > 0
        let passed = abs(duration.seconds - expectedDuration) <= frameTolerance
            && Int(abs(encodedSize.width).rounded()) == spec.width
            && Int(abs(encodedSize.height).rounded()) == spec.height
            && abs(Double(nominalFPS) - Double(spec.fpsNumerator) / Double(spec.fpsDenominator)) < 0.05
            && actualCodec == spec.videoCodec
            && audioMatches
        return DeliveryProbeQCV1(
            durationValue: duration.value,
            durationTimescale: duration.timescale,
            width: Int(abs(encodedSize.width).rounded()),
            height: Int(abs(encodedSize.height).rounded()),
            fpsNumerator: Int(nominalFPS.rounded()),
            fpsDenominator: 1,
            videoCodec: actualCodec,
            audioCodec: audioCodec,
            audioChannels: audioChannels,
            passed: passed
        )
    }

    private static func record(
        _ attempt: DeliveryAttemptV1,
        dataRoot: URL,
        terminal: Bool
    ) throws {
        try DeliveryValidatorV1.validate(attempt: attempt)
        guard terminal == ![.queued, .running].contains(attempt.status) else {
            throw ToolError("Delivery attempt persistence does not match its job status.")
        }
        try safeID(attempt.id)
        let bytes = try PipelineAssemblyStore.canonical(attempt)
        let jobDirectory = dataRoot.appendingPathComponent("\(jobsDirectory)/\(attempt.id)")
        let currentURL = jobDirectory.appendingPathComponent("current.v1.json")
        let eventDirectory = jobDirectory.appendingPathComponent("events")
        let eventURL = eventDirectory.appendingPathComponent(
            "\(attempt.status.rawValue)-\(FileDigest.sha256(of: bytes)).v1.json"
        )
        let attemptURL = dataRoot.appendingPathComponent(
            "\(attemptsDirectory)/\(attempt.id).v1.json"
        )
        var paths = [currentURL, eventURL]
        if terminal { paths.append(attemptURL) }
        if FileManager.default.fileExists(atPath: currentURL.path) {
            let currentData = try Data(contentsOf: currentURL)
            let current = try JSONDecoder().decode(DeliveryAttemptV1.self, from: currentData)
            if ![.queued, .running].contains(current.status) {
                guard currentData == bytes else {
                    throw ToolError("A terminal delivery attempt cannot transition to another status.")
                }
                return
            }
            let allowed: Bool = switch (current.status, attempt.status) {
            case (.queued, .queued), (.queued, .running), (.queued, .failed),
                 (.queued, .cancelled), (.queued, .interrupted),
                 (.running, .running), (.running, .succeeded), (.running, .failed),
                 (.running, .cancelled), (.running, .interrupted):
                true
            default:
                false
            }
            guard allowed else {
                throw ToolError("Delivery attempt status cannot move backward.")
            }
        } else {
            guard attempt.status == .queued else {
                throw ToolError("A delivery attempt must begin in the queued state.")
            }
        }
        try ArtifactTransaction.perform(paths: paths, dataRoot: dataRoot) {
            try FileManager.default.createDirectory(
                at: eventDirectory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: eventURL.path) {
                guard try Data(contentsOf: eventURL) == bytes else {
                    throw ToolError("A delivery job event has different bytes.")
                }
            } else {
                try bytes.write(to: eventURL, options: .atomic)
            }
            try bytes.write(to: currentURL, options: .atomic)
            if terminal {
                try FileManager.default.createDirectory(
                    at: attemptURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: attemptURL.path) {
                    guard try Data(contentsOf: attemptURL) == bytes else {
                        throw ToolError("An immutable delivery attempt has different bytes.")
                    }
                } else {
                    try bytes.write(to: attemptURL, options: .atomic)
                }
            }
        }
    }

    private static func select(_ attempt: DeliveryAttemptV1, dataRoot: URL) throws {
        let url = dataRoot.appendingPathComponent(selectionPath)
        let prior: DeliverySelectionV1
        if FileManager.default.fileExists(atPath: url.path) {
            prior = try JSONDecoder().decode(
                DeliverySelectionV1.self,
                from: Data(contentsOf: ProjectLocalFile.resolve(selectionPath, dataRoot: dataRoot))
            )
        } else {
            prior = .init(masterAttemptID: nil, derivativeAttemptIDs: [:], selectedAt: currentTimestamp())
        }
        let next: DeliverySelectionV1
        switch attempt.spec.targetKind {
        case .master:
            next = .init(
                masterAttemptID: attempt.id,
                derivativeAttemptIDs: prior.derivativeAttemptIDs,
                selectedAt: currentTimestamp()
            )
        case .derivative:
            var derivatives = prior.derivativeAttemptIDs
            derivatives[attempt.spec.id] = attempt.id
            next = .init(
                masterAttemptID: prior.masterAttemptID,
                derivativeAttemptIDs: derivatives,
                selectedAt: currentTimestamp()
            )
        }
        try PipelineAssemblyStore.canonical(next).write(to: url, options: .atomic)
    }

    private static func isCurrent(_ finished: FinishedState, dataRoot: URL) -> Bool {
        guard let planURL = try? ProjectLocalFile.resolve(
            FinishPlanV1.relativePath,
            dataRoot: dataRoot
        ),
        let manifestURL = try? ProjectLocalFile.resolve(
            FinishedTimelineManifestV1.relativePath,
            dataRoot: dataRoot
        ),
        let planData = try? Data(contentsOf: planURL),
        let manifestData = try? Data(contentsOf: manifestURL) else {
            return false
        }
        return planData == finished.planData && manifestData == finished.manifestData
    }

    private static func copy(
        _ attempt: DeliveryAttemptV1,
        status: DeliveryJobStatusV1,
        outputPath: String? = nil,
        outputSHA256: String? = nil,
        outputByteCount: Int64? = nil,
        probeQC: DeliveryProbeQCV1? = nil,
        failures: [String]? = nil,
        completedAt: String? = nil
    ) -> DeliveryAttemptV1 {
        .init(
            id: attempt.id,
            spec: attempt.spec,
            finishedTimelineSHA256: attempt.finishedTimelineSHA256,
            sequenceReviewSHA256: attempt.sequenceReviewSHA256,
            status: status,
            outputPath: outputPath ?? attempt.outputPath,
            outputSHA256: outputSHA256 ?? attempt.outputSHA256,
            outputByteCount: outputByteCount ?? attempt.outputByteCount,
            probeQC: probeQC ?? attempt.probeQC,
            warnings: attempt.warnings,
            failures: failures ?? attempt.failures,
            createdAt: attempt.createdAt,
            completedAt: completedAt ?? attempt.completedAt
        )
    }

    private static func codecID(_ format: ExportFormat) -> String {
        switch format {
        case .h264: "avc1"
        case .h265: "hvc1"
        case .prores: "apcn"
        case .xml, .fcpxml: ""
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }

    private static func cancellableSHA256(
        of url: URL,
        isCancelled: @Sendable () -> Bool
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { throw CancellationError() }
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        if isCancelled() { throw CancellationError() }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func requireCancellableHash(
        _ expectedSHA256: String,
        at relativePath: String,
        dataRoot: URL,
        isCancelled: @Sendable () -> Bool
    ) throws -> URL {
        let url = try ProjectLocalFile.resolve(relativePath, dataRoot: dataRoot)
        let actual = try cancellableSHA256(of: url, isCancelled: isCancelled)
        guard actual == expectedSHA256 else {
            throw ProjectLocalFileError.hashMismatch(
                path: relativePath,
                expected: expectedSHA256,
                actual: actual
            )
        }
        return url
    }

    private static func boundURL(_ path: String, dataRoot: URL) throws -> URL {
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw ToolError("Delivery file is missing: \(path)") }
            return url
        }
        return try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
    }

    private static func safeID(_ id: String) throws {
        guard !id.isEmpty,
              id.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
              }) else {
            throw ToolError("Invalid delivery attempt identity.")
        }
    }
}
