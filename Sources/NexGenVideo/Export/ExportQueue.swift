import AppKit
import CryptoKit
import Foundation
import NexGenEngine

enum ExportJobStatus: String, Sendable, Equatable {
    case pending
    case preparing
    case exporting
    case cancelling
    case completed
    case failed
    case cancelled
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: true
        case .pending, .preparing, .exporting, .cancelling: false
        }
    }
}

enum ExportJobKind: String, Sendable, Equatable {
    case video
    case xml
    case fcpxml
    case project
}

@Observable
@MainActor
final class ExportJob: Identifiable {
    let id: String
    let ownerKey: String
    let projectID: String
    let kind: ExportJobKind
    fileprivate(set) var destinationURL: URL?
    let title: String
    let createdAt: Date
    let durationFrames: Int?
    let fps: Int?
    let width: Int?
    let height: Int?

    fileprivate(set) var status: ExportJobStatus
    fileprivate(set) var progress: Double
    fileprivate(set) var detail: String
    fileprivate(set) var failure: String?
    fileprivate(set) var warnings: [String]
    fileprivate(set) var outputSHA256: String?
    fileprivate(set) var outputByteCount: Int64?
    fileprivate(set) var fcpxmlReport: FCPXMLExportReport?
    fileprivate(set) var projectReport: ProjectPackageExporter.Report?
    fileprivate(set) var acceptsCancellation = true

    init(
        id: String,
        ownerKey: String,
        projectID: String,
        kind: ExportJobKind,
        destinationURL: URL?,
        title: String,
        createdAt: Date = Date(),
        durationFrames: Int? = nil,
        fps: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        status: ExportJobStatus = .pending,
        progress: Double = 0,
        detail: String = "Waiting",
        failure: String? = nil,
        warnings: [String] = [],
        outputSHA256: String? = nil,
        outputByteCount: Int64? = nil,
        fcpxmlReport: FCPXMLExportReport? = nil,
        projectReport: ProjectPackageExporter.Report? = nil
    ) {
        self.id = id
        self.ownerKey = ownerKey
        self.projectID = projectID
        self.kind = kind
        self.destinationURL = destinationURL
        self.title = title
        self.createdAt = createdAt
        self.durationFrames = durationFrames
        self.fps = fps
        self.width = width
        self.height = height
        self.status = status
        self.progress = progress
        self.detail = detail
        self.failure = failure
        self.warnings = warnings
        self.outputSHA256 = outputSHA256
        self.outputByteCount = outputByteCount
        self.fcpxmlReport = fcpxmlReport
        self.projectReport = projectReport
    }

    var canCancel: Bool {
        acceptsCancellation && [.pending, .preparing, .exporting].contains(status)
    }

    var canReveal: Bool {
        status == .completed && destinationURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } == true
    }
}

@Observable
@MainActor
final class ExportQueue {
    static let shared = ExportQueue()

    private(set) var jobs: [ExportJob] = []

    @ObservationIgnored private var jobsByID: [String: ExportJob] = [:]
    @ObservationIgnored private var requests: [String: Request] = [:]
    @ObservationIgnored private var pendingIDs: [String] = []
    @ObservationIgnored private var currentID: String?
    @ObservationIgnored private var activeService: ExportService?
    @ObservationIgnored private var cancellationRequests: Set<String> = []
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var cancellationFlags: [String: ExportCancellationFlag] = [:]
    @ObservationIgnored private var fingerprintsByID: [String: String] = [:]
    @ObservationIgnored private var deliveryRootsByID: [String: URL] = [:]
    @ObservationIgnored private var recoveredDeliveryIdentities: [String: RecoveredDeliveryIdentity] = [:]
    @ObservationIgnored private var completionWaiters: [String: [UUID: CheckedContinuation<ExportJob?, Never>]] = [:]
    @ObservationIgnored private var idleWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

    func jobs(ownerKey: String?) -> [ExportJob] {
        guard let ownerKey else { return [] }
        return jobs.filter { $0.ownerKey == ownerKey }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func activeJob(ownerKey: String?) -> ExportJob? {
        guard let ownerKey else { return nil }
        if let currentID,
           let current = jobsByID[currentID],
           current.ownerKey == ownerKey,
           !current.status.isTerminal {
            return current
        }
        return jobs.first { $0.ownerKey == ownerKey && !$0.status.isTerminal }
    }

    func joinedDeliveryJob(
        editor: EditorViewModel,
        specID: String,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL,
        requestID: String?
    ) throws -> ExportJob? {
        guard let requestID, let ownerKey = editor.openWorkingCopyKey else { return nil }
        let id = try jobID(requestID)
        let expectedFingerprint = fingerprint(
            ownerKey, specID, String(describing: format), resolution.rawValue,
            outputURL.standardizedFileURL.path
        )
        if jobsByID[id] == nil,
           let dataRoot = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) {
            _ = loadPersistedDeliveryJobs(ownerKey: ownerKey, dataRoot: dataRoot)
        }
        if let identity = recoveredDeliveryIdentities[id] {
            guard identity.ownerKey == ownerKey,
                  identity.specID == specID,
                  identity.outputURL == outputURL.standardizedFileURL else {
                throw ToolError("An export job with this ID is already bound to different inputs.")
            }
            return jobsByID[id]
        }
        return try joinedJob(id: id, fingerprint: expectedFingerprint)
    }

    func enqueueDelivery(
        editor: EditorViewModel,
        spec: DeliverySpecV1,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL,
        requestID: String? = nil
    ) async throws -> ExportJob {
        guard let root = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: root),
              let ownerKey = editor.openWorkingCopyKey else {
            throw ToolError("Open a project before exporting a delivery.")
        }
        let id = try jobID(requestID)
        let fingerprint = fingerprint(
            ownerKey, spec.id, String(describing: format), resolution.rawValue,
            outputURL.standardizedFileURL.path
        )
        if let existing = try joinedJob(id: id, fingerprint: fingerprint) {
            return existing
        }
        let timeline = editor.timeline
        let resolver = editor.mediaResolver.snapshot()
        let job = registerPreparing(
            id: id,
            ownerKey: ownerKey,
            projectID: editor.projectId ?? ownerKey,
            kind: .video,
            title: outputURL.lastPathComponent,
            timeline: timeline,
            fingerprint: fingerprint,
            deliveryRoot: dataRoot
        )
        let cancellationFlag = cancellationFlags[id] ?? ExportCancellationFlag()
        var preparedFrozen: FrozenSources?
        do {
            let prepared = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ExportPublishRecoveryStore.recoverAll()
                    let finished = try PipelineDeliveryStore.requireCurrentFinished(
                        dataRoot: dataRoot,
                        timeline: timeline,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                    let extensionFiles = try PipelineDeliveryStore.extensionFiles(
                        for: spec,
                        dataRoot: dataRoot
                    )
                    let source = try SourceBinding.video(
                        timeline: timeline,
                        resolver: resolver,
                        additionalFiles: extensionFiles,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                    let destination = try DestinationBinding(
                        url: outputURL,
                        jobID: id,
                        expectsDirectory: false,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                    try source.rejectDestination(destination.url)
                    let frozen = try source.freeze(
                        jobID: id,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                    do {
                        try source.verify(isCancelled: { cancellationFlag.isCancelled })
                        try frozen.verify(isCancelled: { cancellationFlag.isCancelled })
                        try PipelineDeliveryStore.requireBoundFinished(
                            dataRoot: dataRoot,
                            finished: finished,
                            timeline: timeline,
                            resolver: resolver,
                            isCancelled: { cancellationFlag.isCancelled }
                        )
                    } catch {
                        frozen.remove()
                        throw error
                    }
                    return PreparedDelivery(
                        source: source,
                        frozen: frozen,
                        destination: destination,
                        finished: finished
                    )
                }.value
            } onCancel: {
                cancellationFlag.cancel()
            }
            preparedFrozen = prepared.frozen
            try requireEnqueueContext(editor: editor, ownerKey: ownerKey, root: root, jobID: id)
            try throwIfCancelled(id)
            try recoverInterruptedDeliveries(ownerKey: ownerKey, dataRoot: dataRoot)
            try ProjectWorkingCopy.markDirty(key: ownerKey)
            let attempt = try PipelineDeliveryStore.enqueueAttempt(
                id: id,
                dataRoot: dataRoot,
                finished: prepared.finished,
                spec: spec,
                format: format,
                resolution: resolution,
                outputURL: prepared.destination.url,
                timeline: timeline,
                resolver: resolver,
                bindingAlreadyValidated: true
            )
            let payload = DeliveryPayload(
                dataRoot: dataRoot,
                timeline: timeline,
                resolver: resolver,
                finished: prepared.finished,
                spec: spec,
                format: format,
                resolution: resolution,
                attempt: attempt
            )
            install(Request(
                id: id,
                ownerKey: ownerKey,
                projectID: prepared.finished.plan.projectID,
                kind: .video,
                title: prepared.destination.url.lastPathComponent,
                durationFrames: timeline.totalFrames,
                fps: timeline.fps,
                width: timeline.width,
                height: timeline.height,
                fingerprint: fingerprint,
                source: prepared.source,
                frozenSources: prepared.frozen,
                destination: prepared.destination,
                companionDestination: nil,
                payload: .delivery(payload),
                changeHandler: projectChangeHandler(editor: editor, ownerKey: ownerKey, root: root),
                currentHandler: projectCurrentHandler(
                    editor: editor,
                    ownerKey: ownerKey,
                    root: root,
                    timelineSHA256: prepared.finished.manifest.timelineSHA256
                ),
                ownershipHandler: projectOwnershipHandler(editor: editor, ownerKey: ownerKey, root: root)
            ), for: job)
            preparedFrozen = nil
            return job
        } catch {
            preparedFrozen?.remove()
            failPreparation(job, error: error)
            throw error
        }
    }

    func enqueueInterchange(
        editor: EditorViewModel,
        format: ExportFormat,
        outputURL: URL,
        projectName: String,
        fcpxmlVersion: FCPXMLVersion = .default,
        fcpxmlTarget: FCPXMLTarget = .default,
        requestID: String? = nil
    ) async throws -> ExportJob {
        guard format == .xml || format == .fcpxml else {
            throw ToolError("Interchange jobs require XML or FCPXML.")
        }
        guard let root = editor.workingRoot,
              let ownerKey = editor.openWorkingCopyKey else {
            throw ToolError("Open a project before exporting interchange.")
        }
        let id = try jobID(requestID)
        let fingerprint = fingerprint(
            ownerKey, String(describing: format), fcpxmlVersion.rawValue,
            fcpxmlTarget.rawValue, projectName, outputURL.standardizedFileURL.path
        )
        if let existing = try joinedJob(id: id, fingerprint: fingerprint) {
            return existing
        }
        let timeline = editor.timeline
        let resolver = editor.mediaResolver.snapshot()
        let payload = InterchangePayload(
            timeline: timeline,
            resolver: resolver,
            format: format,
            projectName: projectName,
            fcpxmlVersion: fcpxmlVersion,
            fcpxmlTarget: fcpxmlTarget
        )
        let job = registerPreparing(
            id: id,
            ownerKey: ownerKey,
            projectID: editor.projectId ?? ownerKey,
            kind: format == .xml ? .xml : .fcpxml,
            title: outputURL.lastPathComponent,
            timeline: timeline,
            fingerprint: fingerprint,
            deliveryRoot: nil
        )
        let cancellationFlag = cancellationFlags[id] ?? ExportCancellationFlag()
        var preparedFrozen: FrozenSources?
        do {
            let prepared = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ExportPublishRecoveryStore.recoverAll()
                    let source = try SourceBinding.interchange(
                        timeline: timeline,
                        resolver: resolver,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                    let destination = try DestinationBinding(
                        url: outputURL,
                        jobID: id,
                        expectsDirectory: false,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                    try source.rejectDestination(destination.url)
                    let companion: DestinationBinding?
                    if format == .fcpxml {
                        companion = try DestinationBinding(
                            url: FCPXMLExporter.mediaDirectory(for: destination.url),
                            jobID: id,
                            expectsDirectory: true,
                            isCancelled: { cancellationFlag.isCancelled }
                        )
                        try source.rejectDestination(companion!.url)
                    } else {
                        companion = nil
                    }
                    let frozen = try source.freeze(
                        jobID: id,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                    do {
                        try source.verify(isCancelled: { cancellationFlag.isCancelled })
                        try frozen.verify(isCancelled: { cancellationFlag.isCancelled })
                    } catch {
                        frozen.remove()
                        throw error
                    }
                    return PreparedSources(
                        source: source,
                        frozen: frozen,
                        destination: destination,
                        companionDestination: companion
                    )
                }.value
            } onCancel: {
                cancellationFlag.cancel()
            }
            preparedFrozen = prepared.frozen
            try requireEnqueueContext(editor: editor, ownerKey: ownerKey, root: root, jobID: id)
            try throwIfCancelled(id)
            install(Request(
                id: id,
                ownerKey: ownerKey,
                projectID: editor.projectId ?? ownerKey,
                kind: format == .xml ? .xml : .fcpxml,
                title: prepared.destination.url.lastPathComponent,
                durationFrames: timeline.totalFrames,
                fps: timeline.fps,
                width: timeline.width,
                height: timeline.height,
                fingerprint: fingerprint,
                source: prepared.source,
                frozenSources: prepared.frozen,
                destination: prepared.destination,
                companionDestination: prepared.companionDestination,
                payload: .interchange(payload),
                changeHandler: projectChangeHandler(editor: editor, ownerKey: ownerKey, root: root),
                currentHandler: { false },
                ownershipHandler: projectOwnershipHandler(editor: editor, ownerKey: ownerKey, root: root)
            ), for: job)
            preparedFrozen = nil
            return job
        } catch {
            preparedFrozen?.remove()
            failPreparation(job, error: error)
            throw error
        }
    }

    func enqueueProjectPackage(
        editor: EditorViewModel,
        outputURL: URL,
        requestID: String? = nil
    ) async throws -> ExportJob {
        guard let root = editor.workingRoot,
              let ownerKey = editor.openWorkingCopyKey else {
            throw ToolError("Open a project before exporting a NexGenVideo project.")
        }
        let id = try jobID(requestID)
        let fingerprint = fingerprint(
            ownerKey, ExportJobKind.project.rawValue, outputURL.standardizedFileURL.path
        )
        if let existing = try joinedJob(id: id, fingerprint: fingerprint) {
            return existing
        }
        let timeline = editor.timeline
        let manifest = editor.mediaManifest
        let generationLog = editor.generationLog
        let sourcePath = root.standardizedFileURL.path
        let standardizedOutput = outputURL.standardizedFileURL
        guard standardizedOutput.path != sourcePath,
              !standardizedOutput.path.hasPrefix(sourcePath + "/") else {
            throw ToolError("Export the project package outside its source working copy.")
        }
        let payload = ProjectPayload(
            timeline: timeline,
            manifest: manifest,
            generationLog: generationLog,
            sourceRoot: root
        )
        let job = registerPreparing(
            id: id,
            ownerKey: ownerKey,
            projectID: editor.projectId ?? ownerKey,
            kind: .project,
            title: standardizedOutput.lastPathComponent,
            timeline: timeline,
            fingerprint: fingerprint,
            deliveryRoot: nil
        )
        let cancellationFlag = cancellationFlags[id] ?? ExportCancellationFlag()
        var preparedFrozen: FrozenSources?
        do {
            let prepared = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ExportPublishRecoveryStore.recoverAll()
                    let source = try SourceBinding.projectPackage(
                        timeline: timeline,
                        manifest: manifest,
                        sourceRoot: root,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                    let destination = try DestinationBinding(
                        url: standardizedOutput,
                        jobID: id,
                        expectsDirectory: true,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                    let resolvedSource = root.standardizedFileURL.resolvingSymlinksInPath()
                    guard destination.url != resolvedSource,
                          !destination.url.path.hasPrefix(resolvedSource.path + "/") else {
                        throw ToolError("Export the project package outside its source working copy.")
                    }
                    try source.rejectDestination(destination.url)
                    let frozen = try source.freeze(
                        jobID: id,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                    do {
                        try source.verify(isCancelled: { cancellationFlag.isCancelled })
                        try frozen.verify(isCancelled: { cancellationFlag.isCancelled })
                    } catch {
                        frozen.remove()
                        throw error
                    }
                    return PreparedSources(
                        source: source,
                        frozen: frozen,
                        destination: destination,
                        companionDestination: nil
                    )
                }.value
            } onCancel: {
                cancellationFlag.cancel()
            }
            preparedFrozen = prepared.frozen
            try requireEnqueueContext(editor: editor, ownerKey: ownerKey, root: root, jobID: id)
            try throwIfCancelled(id)
            install(Request(
                id: id,
                ownerKey: ownerKey,
                projectID: editor.projectId ?? ownerKey,
                kind: .project,
                title: prepared.destination.url.lastPathComponent,
                durationFrames: timeline.totalFrames,
                fps: timeline.fps,
                width: timeline.width,
                height: timeline.height,
                fingerprint: fingerprint,
                source: prepared.source,
                frozenSources: prepared.frozen,
                destination: prepared.destination,
                companionDestination: nil,
                payload: .project(payload),
                changeHandler: projectChangeHandler(editor: editor, ownerKey: ownerKey, root: root),
                currentHandler: { false },
                ownershipHandler: projectOwnershipHandler(editor: editor, ownerKey: ownerKey, root: root)
            ), for: job)
            preparedFrozen = nil
            return job
        } catch {
            preparedFrozen?.remove()
            failPreparation(job, error: error)
            throw error
        }
    }

    func cancel(jobID: String) {
        guard let job = jobsByID[jobID], job.canCancel else { return }
        cancellationRequests.insert(jobID)
        cancellationFlags[jobID]?.cancel()
        if currentID != jobID, job.status == .preparing {
            job.status = .cancelling
            job.detail = "Cancelling"
        } else if job.status == .pending, currentID != jobID {
            do {
                try recordCancellation(for: jobID, reason: "Export cancelled before preparation.")
                job.status = .cancelled
                job.detail = "Cancelled"
                job.failure = "Export cancelled"
            } catch {
                job.status = .failed
                job.detail = "Failed"
                job.failure = error.localizedDescription
            }
            requests[jobID]?.changeHandler()
            cancellationFlags.removeValue(forKey: jobID)
            cancellationRequests.remove(jobID)
            resumeWaiters(for: job)
        } else {
            job.status = .cancelling
            job.detail = "Cancelling"
            activeService?.cancel()
        }
    }

    func cancelAll(ownerKey: String) {
        for job in jobs where job.ownerKey == ownerKey && job.canCancel {
            cancel(jobID: job.id)
        }
    }

    func release(ownerKey: String) {
        guard !hasActiveJobs(ownerKey: ownerKey) else { return }
        let ids = jobs.filter { $0.ownerKey == ownerKey }.map(\.id)
        let roots = Set(ids.compactMap { requests[$0]?.frozenSources.root })
        for root in roots { try? FileManager.default.removeItem(at: root) }
        jobs.removeAll { $0.ownerKey == ownerKey }
        for id in ids {
            jobsByID.removeValue(forKey: id)
            requests.removeValue(forKey: id)
            fingerprintsByID.removeValue(forKey: id)
            deliveryRootsByID.removeValue(forKey: id)
            recoveredDeliveryIdentities.removeValue(forKey: id)
            cancellationFlags.removeValue(forKey: id)
            cancellationRequests.remove(id)
            pendingIDs.removeAll { $0 == id }
        }
    }

    func canRetry(jobID: String) -> Bool {
        guard let job = jobsByID[jobID] else { return false }
        return [.failed, .cancelled].contains(job.status) && requests[jobID] != nil
    }

    func retry(jobID: String) throws -> ExportJob {
        guard let job = jobsByID[jobID],
              [.failed, .cancelled].contains(job.status),
              let request = requests[jobID] else {
            throw ToolError("This export cannot be retried from its bound source.")
        }
        let newID = UUID().uuidString.lowercased()
        var retried = request.withID(newID)
        if case .delivery(let payload) = retried.payload {
            try ProjectWorkingCopy.markDirty(key: retried.ownerKey)
            let attempt = try PipelineDeliveryStore.enqueueAttempt(
                id: newID,
                dataRoot: payload.dataRoot,
                finished: payload.finished,
                spec: payload.spec,
                format: payload.format,
                resolution: payload.resolution,
                outputURL: retried.destination.url,
                timeline: payload.timeline,
                resolver: payload.resolver,
                bindingAlreadyValidated: true
            )
            retried.payload = .delivery(payload.withAttempt(attempt))
        }
        return register(retried)
    }

    func waitForCompletion(jobID: String) async -> ExportJob? {
        if Task.isCancelled { return jobsByID[jobID] }
        guard let job = jobsByID[jobID], !job.status.isTerminal else {
            return jobsByID[jobID]
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      let current = jobsByID[jobID],
                      !current.status.isTerminal else {
                    continuation.resume(returning: jobsByID[jobID])
                    return
                }
                completionWaiters[jobID, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCompletionWaiter(jobID: jobID, waiterID: waiterID)
            }
        }
    }

    func waitUntilIdle(ownerKey: String) async {
        if Task.isCancelled || !hasActiveJobs(ownerKey: ownerKey) { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, hasActiveJobs(ownerKey: ownerKey) else {
                    continuation.resume()
                    return
                }
                idleWaiters[ownerKey, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelIdleWaiter(ownerKey: ownerKey, waiterID: waiterID)
            }
        }
    }

    @discardableResult
    func loadPersistedDeliveryJobs(ownerKey: String?, dataRoot: URL?) -> Bool {
        guard let ownerKey, let dataRoot else { return false }
        var recovered = false
        do {
            recovered = try recoverInterruptedDeliveries(
                ownerKey: ownerKey,
                dataRoot: dataRoot
            )
            for attempt in try PipelineDeliveryStore.listAttempts(dataRoot: dataRoot) {
                guard jobsByID[attempt.id] == nil else { continue }
                let status: ExportJobStatus = switch attempt.status {
                case .succeeded: .completed
                case .failed: .failed
                case .cancelled: .cancelled
                case .interrupted: .interrupted
                case .queued, .running: .interrupted
                }
                let destination = attempt.outputPath.map { URL(fileURLWithPath: $0) }
                let boundTimelineURL = dataRoot.appendingPathComponent(
                    "delivery/timelines/\(attempt.finishedTimelineSHA256).json"
                )
                let boundTimeline = try? JSONDecoder().decode(
                    Timeline.self,
                    from: Data(contentsOf: boundTimelineURL)
                )
                let job = ExportJob(
                    id: attempt.id,
                    ownerKey: ownerKey,
                    projectID: ownerKey,
                    kind: .video,
                    destinationURL: destination,
                    title: destination?.lastPathComponent ?? "Interrupted export",
                    durationFrames: boundTimeline?.totalFrames,
                    fps: boundTimeline?.fps ?? attempt.spec.fpsNumerator,
                    width: boundTimeline?.width ?? attempt.spec.width,
                    height: boundTimeline?.height ?? attempt.spec.height,
                    status: status,
                    progress: status == .completed ? 1 : 0,
                    detail: status == .completed ? "Completed" : status.rawValue.capitalized,
                    failure: attempt.failures.first,
                    warnings: attempt.warnings,
                    outputSHA256: attempt.outputSHA256,
                    outputByteCount: attempt.outputByteCount
                )
                jobs.append(job)
                jobsByID[job.id] = job
                recoveredDeliveryIdentities[job.id] = .init(
                    ownerKey: ownerKey,
                    specID: attempt.spec.id,
                    outputURL: destination?.standardizedFileURL
                )
                if attempt.status == .interrupted {
                    cleanupTemporaryState(for: attempt)
                }
            }
            return recovered
        } catch {
            Log.export.error("delivery history load failed: \(error.localizedDescription)")
            return recovered
        }
    }

    private func registerPreparing(
        id: String,
        ownerKey: String,
        projectID: String,
        kind: ExportJobKind,
        title: String,
        timeline: Timeline,
        fingerprint: String,
        deliveryRoot: URL?
    ) -> ExportJob {
        let job = ExportJob(
            id: id,
            ownerKey: ownerKey,
            projectID: projectID,
            kind: kind,
            destinationURL: nil,
            title: title,
            durationFrames: timeline.totalFrames,
            fps: timeline.fps,
            width: timeline.width,
            height: timeline.height,
            status: .preparing,
            detail: "Preparing"
        )
        jobs.append(job)
        jobsByID[job.id] = job
        fingerprintsByID[id] = fingerprint
        if let deliveryRoot { deliveryRootsByID[id] = deliveryRoot.standardizedFileURL }
        cancellationFlags[job.id] = ExportCancellationFlag()
        return job
    }

    private func install(_ request: Request, for job: ExportJob) {
        guard jobsByID[job.id] === job, !job.status.isTerminal else {
            request.frozenSources.remove()
            return
        }
        requests[job.id] = request
        job.destinationURL = request.destination.url
        job.status = .pending
        job.detail = "Waiting"
        pendingIDs.append(job.id)
        startDrainIfNeeded()
    }

    private func register(_ request: Request) -> ExportJob {
        let job = registerPreparing(
            id: request.id,
            ownerKey: request.ownerKey,
            projectID: request.projectID,
            kind: request.kind,
            title: request.title,
            timeline: request.payload.timeline,
            fingerprint: request.fingerprint,
            deliveryRoot: request.payload.dataRoot
        )
        install(request, for: job)
        return job
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !pendingIDs.isEmpty {
            let id = pendingIDs.removeFirst()
            guard let job = jobsByID[id], !job.status.isTerminal,
                  let request = requests[id] else { continue }
            currentID = id
            await run(request, job: job)
            currentID = nil
            activeService = nil
        }
        drainTask = nil
    }

    private func run(_ request: Request, job: ExportJob) async {
        let temporaryURL = request.destination.temporaryURL
        let companionTemporaryURL = request.companionDestination.map { _ in
            FCPXMLExporter.mediaDirectory(for: temporaryURL)
        }
        var deliveryAttempt: DeliveryAttemptV1?
        var published = false
        do {
            try throwIfCancelled(job.id)
            let cancellationFlag = cancellationFlags[job.id] ?? ExportCancellationFlag()
            try await ExportCoordinator.acquireExport(
                isCancelled: { cancellationFlag.isCancelled }
            )
            defer { ExportCoordinator.endExport() }
            try requireCurrent(request, job: job)
            try throwIfCancelled(job.id)

            job.status = .preparing
            job.detail = "Preparing"
            await Task.yield()
            try requireCurrent(request, job: job)
            try throwIfCancelled(job.id)
            if case .delivery(let payload) = request.payload {
                try ProjectWorkingCopy.markDirty(key: request.ownerKey)
                deliveryAttempt = try PipelineDeliveryStore.markRunning(
                    payload.attempt,
                    dataRoot: payload.dataRoot
                )
                request.changeHandler()
                let dataRoot = payload.dataRoot
                let finished = payload.finished
                let timeline = payload.timeline
                let resolver = payload.resolver
                try await Task.detached(priority: .userInitiated) {
                    try PipelineDeliveryStore.requireBoundFinished(
                        dataRoot: dataRoot,
                        finished: finished,
                        timeline: timeline,
                        resolver: resolver,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                }.value
                try requireCurrent(request, job: job)
            }
            let source = request.source
            let frozen = request.frozenSources
            try await Task.detached(priority: .userInitiated) {
                try source.verify(isCancelled: { cancellationFlag.isCancelled })
                try frozen.verify(isCancelled: { cancellationFlag.isCancelled })
            }.value
            try requireCurrent(request, job: job)
            try throwIfCancelled(job.id)

            let service = ExportService()
            activeService = service
            let event: @MainActor @Sendable (ExportService.Event) -> Void = { [weak job] event in
                guard let job, job.status != .cancelling else { return }
                switch event {
                case .preparing:
                    job.status = .preparing
                    job.detail = "Preparing"
                case .exporting:
                    job.status = .exporting
                    job.detail = "Exporting"
                case .progress(let value):
                    job.progress = min(1, max(0, value))
                }
            }

            var fcpxmlReport: FCPXMLExportReport?
            var projectReport: ProjectPackageExporter.Report?
            switch request.payload {
            case .delivery(let payload):
                await service.export(
                    timeline: payload.timeline,
                    resolver: frozen.resolver(basedOn: payload.resolver),
                    format: payload.format,
                    resolution: payload.resolution,
                    outputURL: temporaryURL,
                    acquireSlot: false,
                    event: event
                )
            case .interchange(let payload):
                await service.export(
                    timeline: payload.timeline,
                    resolver: frozen.resolver(basedOn: payload.resolver),
                    format: payload.format,
                    resolution: .matchTimeline,
                    outputURL: temporaryURL,
                    projectName: payload.projectName,
                    fcpxmlVersion: payload.fcpxmlVersion,
                    fcpxmlTarget: payload.fcpxmlTarget,
                    referenceOutputURL: request.destination.url,
                    acquireSlot: false,
                    event: event
                )
                fcpxmlReport = service.lastFCPXMLReport
            case .project(let payload):
                projectReport = await service.exportProjectPackage(
                    timeline: payload.timeline,
                    manifest: frozen.manifest(basedOn: payload.manifest),
                    generationLog: payload.generationLog,
                    sourceProjectURL: frozen.projectRoot ?? payload.sourceRoot,
                    outputURL: temporaryURL,
                    acquireSlot: false,
                    event: event
                )
            }
            try requireCurrent(request, job: job)

            if let error = service.error {
                if cancellationRequests.contains(job.id) || error == "Export was cancelled" {
                    throw CancellationError()
                }
                throw ToolError(error)
            }
            try throwIfCancelled(job.id)
            try await Task.detached(priority: .userInitiated) {
                try source.verify(isCancelled: { cancellationFlag.isCancelled })
                try frozen.verify(isCancelled: { cancellationFlag.isCancelled })
            }.value
            try requireCurrent(request, job: job)
            if case .delivery(let payload) = request.payload {
                let dataRoot = payload.dataRoot
                let finished = payload.finished
                let timeline = payload.timeline
                let resolver = payload.resolver
                try await Task.detached(priority: .userInitiated) {
                    try PipelineDeliveryStore.requireBoundFinished(
                        dataRoot: dataRoot,
                        finished: finished,
                        timeline: timeline,
                        resolver: resolver,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                }.value
                try requireCurrent(request, job: job)
            }

            let deliveryEvidence: PipelineDeliveryStore.OutputEvidence?
            if case .delivery(let payload) = request.payload {
                deliveryEvidence = try await PipelineDeliveryStore.inspectSuccessfulOutput(
                    outputURL: temporaryURL,
                    spec: payload.spec,
                    expectedDurationFrames: payload.timeline.totalFrames,
                    isCancelled: { cancellationFlag.isCancelled }
                )
            } else {
                deliveryEvidence = nil
            }
            try requireCurrent(request, job: job)
            try throwIfCancelled(job.id)
            try await Task.detached(priority: .userInitiated) {
                try source.verify(isCancelled: { cancellationFlag.isCancelled })
                try frozen.verify(isCancelled: { cancellationFlag.isCancelled })
            }.value
            try requireCurrent(request, job: job)
            if case .delivery(let payload) = request.payload {
                let dataRoot = payload.dataRoot
                let finished = payload.finished
                let timeline = payload.timeline
                let resolver = payload.resolver
                try await Task.detached(priority: .userInitiated) {
                    try PipelineDeliveryStore.requireBoundFinished(
                        dataRoot: dataRoot,
                        finished: finished,
                        timeline: timeline,
                        resolver: resolver,
                        isCancelled: { cancellationFlag.isCancelled }
                    )
                }.value
                try requireCurrent(request, job: job)
                try ProjectWorkingCopy.markDirty(key: request.ownerKey)
            }
            var publications = [DestinationBinding.Publication(
                binding: request.destination,
                temporaryURL: temporaryURL
            )]
            if let companionDestination = request.companionDestination,
               let companionTemporaryURL,
               FileManager.default.fileExists(atPath: companionTemporaryURL.path) {
                publications.append(.init(
                    binding: companionDestination,
                    temporaryURL: companionTemporaryURL
                ))
            }
            job.acceptsCancellation = false
            job.detail = "Publishing"
            let publicationResult = try await Task.detached(priority: .userInitiated) {
                try DestinationBinding.publish(
                    publications,
                    isCancelled: { cancellationFlag.isCancelled }
                )
            }.value
            published = true
            try requireQueueIdentity(request, job: job)
            try await Task.detached(priority: .userInitiated) {
                try publicationResult.verifyPublished(
                    isCancelled: { false }
                )
            }.value
            try requireQueueIdentity(request, job: job)

            switch request.payload {
            case .delivery(let payload):
                guard let running = deliveryAttempt, let deliveryEvidence else {
                    throw ToolError("The delivery job lost its bound receipt state.")
                }
                let result = try PipelineDeliveryStore.finishSuccessful(
                    running,
                    dataRoot: payload.dataRoot,
                    finished: payload.finished,
                    outputURL: request.destination.url,
                    evidence: deliveryEvidence,
                    publishedState: publicationResult.state(for: request.destination.url),
                    selectIfCurrent: request.currentHandler()
                )
                job.outputSHA256 = result.attempt.outputSHA256
                job.outputByteCount = result.attempt.outputByteCount
                if let selectionWarning = result.selectionWarning {
                    job.warnings.append(selectionWarning)
                }
                request.changeHandler()
            case .interchange:
                guard case .file(let sha256, let size) = publicationResult.state(
                    for: request.destination.url
                ), size > 0 else {
                    throw ToolError("The exported interchange file is missing or empty.")
                }
                job.outputSHA256 = sha256
                job.outputByteCount = Int64(size)
                job.fcpxmlReport = fcpxmlReport
                job.warnings = fcpxmlReport?.warnings.map(\.message) ?? []
            case .project:
                let state = publicationResult.state(for: request.destination.url)
                job.outputSHA256 = state.digest
                job.outputByteCount = projectReport?.totalBytes
                job.projectReport = projectReport
                if let projectReport, !projectReport.missing.isEmpty {
                    job.warnings = [
                        "\(projectReport.missing.count) media file\(projectReport.missing.count == 1 ? "" : "s") could not be included."
                    ]
                }
            }

            job.progress = 1
            job.status = .completed
            job.detail = "Completed"
            resumeWaiters(for: job)
            AppNotifications.exportComplete(
                name: job.title,
                outputURL: request.destination.url,
                size: nil,
                warningCount: job.warnings.count
            )
        } catch {
            if !published {
                try? FileManager.default.removeItem(at: temporaryURL)
                if let companionTemporaryURL {
                    try? FileManager.default.removeItem(at: companionTemporaryURL)
                }
            }
            let cancelled = cancellationRequests.contains(job.id) || error is CancellationError
            let reason = cancelled ? "Export cancelled" : error.localizedDescription
            if case .delivery(let payload) = request.payload,
               let attempt = deliveryAttempt ?? Optional(payload.attempt),
               attempt.status != .succeeded {
                do {
                    try ProjectWorkingCopy.markDirty(key: request.ownerKey)
                    _ = try PipelineDeliveryStore.finishUnsuccessful(
                        attempt,
                        status: cancelled ? .cancelled : .failed,
                        reason: reason,
                        dataRoot: payload.dataRoot
                    )
                    request.changeHandler()
                } catch {
                    job.failure = "\(reason) Receipt error: \(error.localizedDescription)"
                }
            }
            job.status = cancelled ? .cancelled : .failed
            job.detail = cancelled ? "Cancelled" : "Failed"
            if job.failure == nil { job.failure = reason }
            if !cancelled {
                AppNotifications.exportFailed(name: job.title, reason: reason)
            }
            resumeWaiters(for: job)
        }
        cancellationRequests.remove(job.id)
        cancellationFlags.removeValue(forKey: job.id)
    }

    private func recordCancellation(for id: String, reason: String) throws {
        guard let request = requests[id], case .delivery(let payload) = request.payload else { return }
        try ProjectWorkingCopy.markDirty(key: request.ownerKey)
        _ = try PipelineDeliveryStore.finishUnsuccessful(
            payload.attempt,
            status: .cancelled,
            reason: reason,
            dataRoot: payload.dataRoot
        )
    }

    private func throwIfCancelled(_ id: String) throws {
        if cancellationRequests.contains(id) || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func requireCurrent(_ request: Request, job: ExportJob) throws {
        try requireQueueIdentity(request, job: job)
        guard request.ownershipHandler() else {
            throw CancellationError()
        }
    }

    private func requireQueueIdentity(_ request: Request, job: ExportJob) throws {
        guard jobsByID[job.id] === job,
              requests[job.id]?.fingerprint == request.fingerprint else {
            throw CancellationError()
        }
    }

    private func joinedJob(id: String, fingerprint: String) throws -> ExportJob? {
        guard let existing = jobsByID[id] else { return nil }
        guard fingerprintsByID[id] == fingerprint else {
            throw ToolError("An export job with this ID is already bound to different inputs.")
        }
        return existing
    }

    private func jobID(_ supplied: String?) throws -> String {
        guard let supplied else { return UUID().uuidString.lowercased() }
        guard let uuid = UUID(uuidString: supplied) else {
            throw ToolError("Export requestID must be a UUID.")
        }
        return uuid.uuidString.lowercased()
    }

    private func fingerprint(_ parts: String...) -> String {
        FileDigest.sha256(of: Data(parts.joined(separator: "\u{0}").utf8))
    }

    func activeDeliveryIDs(dataRoot: URL) -> Set<String> {
        let root = dataRoot.standardizedFileURL
        return Set(deliveryRootsByID.compactMap { id, candidate in
            guard candidate == root,
                  let job = jobsByID[id],
                  !job.status.isTerminal else { return nil }
            return id
        })
    }

    @discardableResult
    func recoverInterruptedDeliveries(ownerKey: String, dataRoot: URL) throws -> Bool {
        try PipelineDeliveryStore.recoverInterruptedJobs(
            dataRoot: dataRoot,
            excludingIDs: activeDeliveryIDs(dataRoot: dataRoot),
            willMutate: { try ProjectWorkingCopy.markDirty(key: ownerKey) },
            didRecover: { cleanupTemporaryState(for: $0) }
        )
    }

    private func requireEnqueueContext(
        editor: EditorViewModel,
        ownerKey: String,
        root: URL,
        jobID: String
    ) throws {
        guard jobsByID[jobID]?.status.isTerminal == false,
              editor.openWorkingCopyKey == ownerKey,
              editor.workingRoot?.standardizedFileURL == root.standardizedFileURL else {
            throw CancellationError()
        }
    }

    private func failPreparation(_ job: ExportJob, error: Error) {
        guard !job.status.isTerminal else { return }
        let cancelled = cancellationRequests.contains(job.id)
            || cancellationFlags[job.id]?.isCancelled == true
            || error is CancellationError
        job.status = cancelled ? .cancelled : .failed
        job.detail = cancelled ? "Cancelled" : "Failed"
        job.failure = cancelled ? "Export cancelled" : error.localizedDescription
        cancellationRequests.remove(job.id)
        cancellationFlags.removeValue(forKey: job.id)
        resumeWaiters(for: job)
    }

    private func hasActiveJobs(ownerKey: String) -> Bool {
        jobs.contains { $0.ownerKey == ownerKey && !$0.status.isTerminal }
    }

    private func resumeWaiters(for job: ExportJob) {
        guard job.status.isTerminal else { return }
        let completions = completionWaiters.removeValue(forKey: job.id) ?? [:]
        for continuation in completions.values {
            continuation.resume(returning: job)
        }
        guard !hasActiveJobs(ownerKey: job.ownerKey) else { return }
        let idle = idleWaiters.removeValue(forKey: job.ownerKey) ?? [:]
        for continuation in idle.values { continuation.resume() }
    }

    private func cancelCompletionWaiter(jobID: String, waiterID: UUID) {
        guard let continuation = completionWaiters[jobID]?.removeValue(forKey: waiterID) else {
            return
        }
        if completionWaiters[jobID]?.isEmpty == true {
            completionWaiters.removeValue(forKey: jobID)
        }
        continuation.resume(returning: jobsByID[jobID])
    }

    private func cancelIdleWaiter(ownerKey: String, waiterID: UUID) {
        guard let continuation = idleWaiters[ownerKey]?.removeValue(forKey: waiterID) else {
            return
        }
        if idleWaiters[ownerKey]?.isEmpty == true {
            idleWaiters.removeValue(forKey: ownerKey)
        }
        continuation.resume()
    }

    private func cleanupTemporaryState(for attempt: DeliveryAttemptV1) {
        if let outputPath = attempt.outputPath {
            let outputURL = URL(fileURLWithPath: outputPath)
            let temporaryURL = DestinationBinding.makeTemporaryURL(
                url: outputURL,
                jobID: attempt.id
            )
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        try? FileManager.default.removeItem(
            at: SourceBinding.snapshotRoot(jobID: attempt.id)
        )
    }

    private func projectChangeHandler(
        editor: EditorViewModel,
        ownerKey: String,
        root: URL
    ) -> @MainActor () -> Void {
        { [weak editor] in
            guard let editor,
                  editor.openWorkingCopyKey == ownerKey,
                  editor.workingRoot?.standardizedFileURL == root.standardizedFileURL else {
                return
            }
            editor.onPipelineChanged?()
        }
    }

    private func projectCurrentHandler(
        editor: EditorViewModel,
        ownerKey: String,
        root: URL,
        timelineSHA256: String
    ) -> @MainActor () -> Bool {
        { [weak editor] in
            guard let editor,
                  editor.openWorkingCopyKey == ownerKey,
                  editor.workingRoot?.standardizedFileURL == root.standardizedFileURL,
                  let timelineData = try? PipelineAssemblyStore.canonical(editor.timeline) else {
                return false
            }
            return FileDigest.sha256(of: timelineData) == timelineSHA256
        }
    }

    private func projectOwnershipHandler(
        editor: EditorViewModel,
        ownerKey: String,
        root: URL
    ) -> @MainActor () -> Bool {
        { [weak editor] in
            guard let editor else { return false }
            return editor.openWorkingCopyKey == ownerKey
                && editor.workingRoot?.standardizedFileURL == root.standardizedFileURL
        }
    }
}

extension ExportQueue {
    struct RecoveredDeliveryIdentity {
        let ownerKey: String
        let specID: String
        let outputURL: URL?
    }

    struct PreparedSources: Sendable {
        let source: SourceBinding
        let frozen: FrozenSources
        let destination: DestinationBinding
        let companionDestination: DestinationBinding?
    }

    struct PreparedDelivery: Sendable {
        let source: SourceBinding
        let frozen: FrozenSources
        let destination: DestinationBinding
        let finished: PipelineDeliveryStore.FinishedState
    }

    struct Request {
        var id: String
        let ownerKey: String
        let projectID: String
        let kind: ExportJobKind
        let title: String
        let durationFrames: Int
        let fps: Int
        let width: Int
        let height: Int
        let fingerprint: String
        let source: SourceBinding
        let frozenSources: FrozenSources
        var destination: DestinationBinding
        var companionDestination: DestinationBinding?
        var payload: Payload
        let changeHandler: @MainActor () -> Void
        let currentHandler: @MainActor () -> Bool
        let ownershipHandler: @MainActor () -> Bool

        func withID(_ id: String) -> Request {
            var copy = self
            copy.id = id
            copy.destination = destination.withJobID(id)
            copy.companionDestination = companionDestination?.withJobID(id)
            return copy
        }
    }

    enum Payload {
        case delivery(DeliveryPayload)
        case interchange(InterchangePayload)
        case project(ProjectPayload)

        var timeline: Timeline {
            switch self {
            case .delivery(let value): value.timeline
            case .interchange(let value): value.timeline
            case .project(let value): value.timeline
            }
        }

        var dataRoot: URL? {
            if case .delivery(let value) = self { return value.dataRoot }
            return nil
        }
    }

    struct DeliveryPayload {
        let dataRoot: URL
        let timeline: Timeline
        let resolver: MediaResolver
        let finished: PipelineDeliveryStore.FinishedState
        let spec: DeliverySpecV1
        let format: ExportFormat
        let resolution: ExportResolution
        let attempt: DeliveryAttemptV1

        func withAttempt(_ attempt: DeliveryAttemptV1) -> DeliveryPayload {
            .init(
                dataRoot: dataRoot,
                timeline: timeline,
                resolver: resolver,
                finished: finished,
                spec: spec,
                format: format,
                resolution: resolution,
                attempt: attempt
            )
        }
    }

    struct InterchangePayload {
        let timeline: Timeline
        let resolver: MediaResolver
        let format: ExportFormat
        let projectName: String
        let fcpxmlVersion: FCPXMLVersion
        let fcpxmlTarget: FCPXMLTarget
    }

    struct ProjectPayload {
        let timeline: Timeline
        let manifest: MediaManifest
        let generationLog: GenerationLog
        let sourceRoot: URL
    }

    struct SourceBinding: Sendable {
        struct Media: Equatable, Sendable {
            let ref: String
            let url: URL
            let state: PathState
            let entry: MediaManifestEntry?
        }

        let timelineSHA256: String
        let media: [Media]
        let rootURL: URL?
        let rootState: PathState?
        let rootExclusions: Set<String>
        let separatelyCapturedPaths: Set<String>
        let excludesWorkingCopyRuntime: Bool
        let verifyLiveRoot: Bool

        static func video(
            timeline: Timeline,
            resolver: MediaResolver,
            additionalFiles: [(path: String, url: URL)],
            isCancelled: @Sendable () -> Bool = { false }
        ) throws -> SourceBinding {
            let tracks = timeline.tracks.filter {
                !$0.hidden && ($0.type != .audio || !$0.muted)
            }
            return try make(
                timeline: timeline,
                refs: mediaRefs(timeline.tracks),
                requiredRefs: mediaRefs(tracks),
                resolver: resolver,
                additionalFiles: additionalFiles,
                isCancelled: isCancelled
            )
        }

        static func interchange(
            timeline: Timeline,
            resolver: MediaResolver,
            isCancelled: @Sendable () -> Bool = { false }
        ) throws -> SourceBinding {
            try make(
                timeline: timeline,
                refs: mediaRefs(timeline.tracks),
                requiredRefs: [],
                resolver: resolver,
                additionalFiles: [],
                isCancelled: isCancelled
            )
        }

        static func projectPackage(
            timeline: Timeline,
            manifest: MediaManifest,
            sourceRoot: URL,
            isCancelled: @Sendable () -> Bool = { false }
        ) throws -> SourceBinding {
            let resolver = MediaResolver(manifest: { manifest }, projectURL: { sourceRoot })
            let refs = Set(manifest.entries.compactMap { entry in
                if case .external = entry.source { return entry.id }
                return nil
            })
            let binding = try make(
                timeline: timeline,
                refs: refs,
                requiredRefs: [],
                resolver: resolver,
                additionalFiles: [],
                isCancelled: isCancelled
            )
            var separatelyCapturedPaths: Set<String> = []
            if let dataRoot = DataRootResolver.dataRoot(of: sourceRoot) {
                let source = sourceRoot.standardizedFileURL
                let data = dataRoot.standardizedFileURL
                let relative = data == source
                    ? ""
                    : String(data.path.dropFirst(source.path.count + 1))
                separatelyCapturedPaths.insert(
                    relative.isEmpty ? "delivery" : "\(relative)/delivery"
                )
            }
            let exclusions = separatelyCapturedPaths
            return .init(
                timelineSHA256: binding.timelineSHA256,
                media: binding.media,
                rootURL: sourceRoot,
                rootState: try PathState.capture(
                    sourceRoot,
                    excluding: exclusions,
                    excludingWorkingCopyRuntime: true,
                    isCancelled: isCancelled
                ),
                rootExclusions: exclusions,
                separatelyCapturedPaths: separatelyCapturedPaths,
                excludesWorkingCopyRuntime: true,
                verifyLiveRoot: false
            )
        }

        func verify(isCancelled: @Sendable () -> Bool = { false }) throws {
            for item in media {
                if isCancelled() { throw CancellationError() }
                guard try PathState.capture(item.url, isCancelled: isCancelled) == item.state else {
                    throw ToolError("Export source changed or is offline: \(item.ref)")
                }
            }
            if verifyLiveRoot, let rootURL, let rootState,
               try PathState.capture(
                   rootURL,
                   excluding: rootExclusions,
                   excludingWorkingCopyRuntime: excludesWorkingCopyRuntime,
                   isCancelled: isCancelled
               ) != rootState {
                throw ToolError("The project source changed after this export was queued.")
            }
        }

        func rejectDestination(_ destination: URL) throws {
            let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
            guard !media.contains(where: {
                $0.url == resolved || $0.url.path.hasPrefix(resolved.path + "/")
            }) else {
                throw ToolError("The export destination cannot replace a bound source file.")
            }
        }

        private static func make(
            timeline: Timeline,
            refs: Set<String>,
            requiredRefs: Set<String>,
            resolver: MediaResolver,
            additionalFiles: [(path: String, url: URL)],
            isCancelled: @Sendable () -> Bool
        ) throws -> SourceBinding {
            let timelineData = try PipelineAssemblyStore.canonical(timeline)
            var media = try refs.sorted().compactMap { ref in
                if isCancelled() { throw CancellationError() }
                guard let url = resolver.expectedURL(for: ref) else {
                    if !requiredRefs.contains(ref) { return nil }
                    throw ToolError("Export source is unresolved: \(resolver.displayName(for: ref))")
                }
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
                let state = try PathState.capture(resolved, isCancelled: isCancelled)
                if state == .absent, requiredRefs.contains(ref) {
                    throw ToolError("Export source is offline: \(resolver.displayName(for: ref))")
                }
                if case .directory = state {
                    throw ToolError("Export source is unreadable: \(resolver.displayName(for: ref))")
                }
                return Media(
                    ref: ref,
                    url: resolved,
                    state: state,
                    entry: resolver.entry(for: ref)
                )
            }
            media += try additionalFiles.map { item in
                if isCancelled() { throw CancellationError() }
                let resolved = item.url.standardizedFileURL.resolvingSymlinksInPath()
                let state = try PathState.capture(resolved, isCancelled: isCancelled)
                guard case .file = state else {
                    throw ToolError("A required delivery extension is missing: \(item.path)")
                }
                return Media(
                    ref: "delivery extension \(item.path)",
                    url: resolved,
                    state: state,
                    entry: nil
                )
            }
            return .init(
                timelineSHA256: FileDigest.sha256(of: timelineData),
                media: media,
                rootURL: nil,
                rootState: nil,
                rootExclusions: [],
                separatelyCapturedPaths: [],
                excludesWorkingCopyRuntime: false,
                verifyLiveRoot: true
            )
        }

        func freeze(
            jobID: String,
            isCancelled: @Sendable () -> Bool
        ) throws -> FrozenSources {
            let fm = FileManager.default
            let root = Self.snapshotRoot(jobID: jobID)
            do {
                guard !fm.fileExists(atPath: root.path) else {
                    throw ToolError("A temporary source snapshot already exists for this export job.")
                }
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                let filesRoot = root.appendingPathComponent("sources", isDirectory: true)
                try fm.createDirectory(at: filesRoot, withIntermediateDirectories: true)
                var frozenFiles: [FrozenSources.File] = []
                for (index, item) in media.enumerated() {
                    if isCancelled() { throw CancellationError() }
                    let ext = item.url.pathExtension
                    let base = "\(index)-\(FileDigest.sha256(of: Data(item.ref.utf8)).prefix(16))"
                    let name = ext.isEmpty ? base : "\(base).\(ext)"
                    let destination = filesRoot.appendingPathComponent(name)
                    switch item.state {
                    case .absent:
                        break
                    case .file:
                        try Self.copyFile(
                            from: item.url,
                            to: destination,
                            isCancelled: isCancelled
                        )
                    case .directory:
                        throw ToolError("Export sources must be regular files.")
                    }
                    guard try PathState.capture(
                        destination,
                        isCancelled: isCancelled
                    ) == item.state else {
                        throw ToolError("Export source could not be frozen: \(item.ref)")
                    }
                    frozenFiles.append(.init(
                        ref: item.ref,
                        url: destination,
                        state: item.state,
                        entry: item.entry
                    ))
                }

                let frozenProjectRoot: URL?
                if let rootURL, let rootState {
                    let destination = root.appendingPathComponent("project", isDirectory: true)
                    try Self.copyDirectory(
                        from: rootURL,
                        to: destination,
                        excluding: rootExclusions,
                        excludingWorkingCopyRuntime: excludesWorkingCopyRuntime,
                        isCancelled: isCancelled
                    )
                    guard try PathState.capture(
                        destination,
                        isCancelled: isCancelled
                    ) == rootState else {
                        throw ToolError("The project source changed while it was being frozen.")
                    }
                    guard try PathState.capture(
                        rootURL,
                        excluding: rootExclusions,
                        excludingWorkingCopyRuntime: excludesWorkingCopyRuntime,
                        isCancelled: isCancelled
                    ) == rootState else {
                        throw ToolError("The project source changed while it was being frozen.")
                    }
                    for relative in separatelyCapturedPaths.sorted() {
                        try Self.copyConsistentDirectory(
                            from: rootURL.appendingPathComponent(relative),
                            to: destination.appendingPathComponent(relative),
                            isCancelled: isCancelled
                        )
                    }
                    frozenProjectRoot = destination
                } else {
                    frozenProjectRoot = nil
                }
                return FrozenSources(
                    root: root,
                    files: frozenFiles,
                    projectRoot: frozenProjectRoot,
                    projectState: frozenProjectRoot.map {
                        try PathState.capture($0, isCancelled: isCancelled)
                    }
                )
            } catch {
                try? fm.removeItem(at: root)
                throw error
            }
        }

        static func snapshotRoot(jobID: String) -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NexGenVideoExportQueue", isDirectory: true)
                .appendingPathComponent(jobID, isDirectory: true)
        }

        private static func copyFile(
            from source: URL,
            to destination: URL,
            isCancelled: @Sendable () -> Bool
        ) throws {
            let fm = FileManager.default
            guard fm.createFile(atPath: destination.path, contents: nil) else {
                throw ToolError("The export source snapshot could not be created.")
            }
            let reader = try FileHandle(forReadingFrom: source)
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: destination)
            defer { try? writer.close() }
            while true {
                if isCancelled() { throw CancellationError() }
                guard let data = try reader.read(upToCount: 1_048_576), !data.isEmpty else {
                    break
                }
                try writer.write(contentsOf: data)
            }
        }

        private static func copyDirectory(
            from source: URL,
            to destination: URL,
            excluding exclusions: Set<String> = [],
            excludingWorkingCopyRuntime: Bool = false,
            isCancelled: @Sendable () -> Bool
        ) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            guard let enumerator = fm.enumerator(
                at: source,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: []
            ) else {
                throw ToolError("The project source snapshot could not be created.")
            }
            for case let item as URL in enumerator {
                if isCancelled() { throw CancellationError() }
                let relative = String(item.path.dropFirst(source.path.count + 1))
                if isExcluded(relative, exclusions: exclusions)
                    || (excludingWorkingCopyRuntime
                        && ProjectWorkingCopy.isPackageRuntimePath(relative)) {
                    enumerator.skipDescendants()
                    continue
                }
                let target = destination.appendingPathComponent(relative)
                let values = try item.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isSymbolicLink != true else {
                    throw ToolError("Export directories cannot contain symbolic links.")
                }
                if values.isDirectory == true {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else if values.isRegularFile == true {
                    try fm.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try copyFile(from: item, to: target, isCancelled: isCancelled)
                } else {
                    throw ToolError("The project source contains an unsupported item: \(relative)")
                }
            }
        }

        private static func copyConsistentDirectory(
            from source: URL,
            to destination: URL,
            isCancelled: @Sendable () -> Bool
        ) throws {
            let fm = FileManager.default
            guard fm.fileExists(atPath: source.path) else { return }
            for _ in 0..<5 {
                if isCancelled() { throw CancellationError() }
                let before = try PathState.capture(source, isCancelled: isCancelled)
                try? fm.removeItem(at: destination)
                try copyDirectory(from: source, to: destination, isCancelled: isCancelled)
                let copied = try PathState.capture(destination, isCancelled: isCancelled)
                let after = try PathState.capture(source, isCancelled: isCancelled)
                if before == after, copied == before { return }
            }
            throw ToolError("The project delivery history changed while it was being frozen.")
        }

        private static func isExcluded(_ relative: String, exclusions: Set<String>) -> Bool {
            exclusions.contains { relative == $0 || relative.hasPrefix($0 + "/") }
        }

        private static func mediaRefs(_ tracks: [Track]) -> Set<String> {
            Set(tracks.flatMap { track in
                track.clips.compactMap { clip in
                    clip.sourceClipType == .text ? nil : clip.mediaRef
                }
            })
        }
    }

    struct DestinationBinding: Sendable {
        struct Publication: Sendable {
            let binding: DestinationBinding
            let temporaryURL: URL
        }

        let url: URL
        let initialState: PathState
        let initialIdentity: ExportFileIdentity?
        let jobID: String
        let temporaryURL: URL
        let expectsDirectory: Bool

        init(
            url: URL,
            jobID: String,
            expectsDirectory: Bool,
            isCancelled: @Sendable () -> Bool = { false }
        ) throws {
            let requested = url.standardizedFileURL
            let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath()
            let standardized = parent.appendingPathComponent(requested.lastPathComponent)
            let values = try parent.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw ToolError("The export destination directory does not exist.")
            }
            let initialState = try PathState.capture(
                standardized,
                isCancelled: isCancelled
            )
            guard !initialState.exists
                    || initialState.isDirectory == expectsDirectory else {
                throw ToolError("The export destination has the wrong file type.")
            }
            self.url = standardized
            self.initialState = initialState
            self.initialIdentity = try ExportFileIdentity.capture(standardized)
            self.jobID = jobID
            self.temporaryURL = Self.makeTemporaryURL(url: standardized, jobID: jobID)
            self.expectsDirectory = expectsDirectory
            guard !FileManager.default.fileExists(atPath: temporaryURL.path) else {
                throw ToolError("A partial export already exists for this job and destination.")
            }
        }

        static func makeTemporaryURL(url: URL, jobID: String) -> URL {
            let parent = url.deletingLastPathComponent()
            let ext = url.pathExtension
            let base = url.deletingPathExtension().lastPathComponent
            let name = ext.isEmpty
                ? ".\(base).\(jobID).partial"
                : ".\(base).\(jobID).partial.\(ext)"
            return parent.appendingPathComponent(name)
        }

        func withJobID(_ jobID: String) -> DestinationBinding {
            .init(
                url: url,
                initialState: initialState,
                initialIdentity: initialIdentity,
                jobID: jobID,
                expectsDirectory: expectsDirectory
            )
        }

        func publish(
            temporaryURL: URL,
            isCancelled: @Sendable () -> Bool = { false }
        ) throws -> ExportPublishRecoveryStore.Result {
            try Self.publish(
                [.init(binding: self, temporaryURL: temporaryURL)],
                isCancelled: isCancelled
            )
        }

        static func publish(
            _ publications: [Publication],
            isCancelled: @Sendable () -> Bool = { false }
        ) throws -> ExportPublishRecoveryStore.Result {
            guard Set(publications.map { $0.binding.url }).count == publications.count else {
                throw ToolError("An export cannot publish two results to the same destination.")
            }
            if isCancelled() { throw CancellationError() }
            var prepared: [ExportPublishRecoveryStore.Publication] = []
            for publication in publications {
                let binding = publication.binding
                guard try PathState.capture(
                    binding.url,
                    isCancelled: isCancelled
                ) == binding.initialState else {
                    throw ToolError("The export destination changed after this job was queued.")
                }
                let temporaryState = try PathState.capture(
                    publication.temporaryURL,
                    isCancelled: isCancelled
                )
                guard temporaryState.exists,
                      temporaryState.isDirectory == binding.expectsDirectory else {
                    throw ToolError("The export produced no temporary result.")
                }
                prepared.append(.init(
                    targetURL: binding.url,
                    temporaryURL: publication.temporaryURL,
                    initialState: binding.initialState,
                    initialIdentity: binding.initialIdentity,
                    publishedState: temporaryState,
                    publishedIdentity: try ExportFileIdentity.capture(
                        publication.temporaryURL
                    ),
                    jobID: binding.jobID,
                    expectsDirectory: binding.expectsDirectory
                ))
            }
            return try ExportPublishRecoveryStore.publish(
                prepared,
                isCancelled: isCancelled
            )
        }

        private init(
            url: URL,
            initialState: PathState,
            initialIdentity: ExportFileIdentity?,
            jobID: String,
            expectsDirectory: Bool
        ) {
            self.url = url
            self.initialState = initialState
            self.initialIdentity = initialIdentity
            self.jobID = jobID
            self.temporaryURL = Self.makeTemporaryURL(url: url, jobID: jobID)
            self.expectsDirectory = expectsDirectory
        }
    }

    struct FrozenSources: Sendable {
        struct File: Sendable {
            let ref: String
            let url: URL
            let state: PathState
            let entry: MediaManifestEntry?
        }

        let root: URL
        let files: [File]
        let projectRoot: URL?
        let projectState: PathState?

        func verify(isCancelled: @Sendable () -> Bool = { false }) throws {
            for file in files {
                if isCancelled() { throw CancellationError() }
                guard try PathState.capture(file.url, isCancelled: isCancelled) == file.state else {
                    throw ToolError("A frozen export source changed: \(file.ref)")
                }
            }
            if let projectRoot, let projectState,
               try PathState.capture(projectRoot, isCancelled: isCancelled) != projectState {
                throw ToolError("The frozen project source changed during export.")
            }
        }

        func resolver(basedOn original: MediaResolver) -> MediaResolver {
            let urls = Dictionary(uniqueKeysWithValues: files.compactMap { file in
                file.entry.map { ($0.id, file.url) }
            })
            return original.snapshot(overriding: urls)
        }

        func manifest(basedOn original: MediaManifest) -> MediaManifest {
            let urls = Dictionary(uniqueKeysWithValues: files.compactMap { file in
                guard case .file = file.state else { return nil }
                return file.entry.map { ($0.id, file.url) }
            })
            var manifest = original
            manifest.entries = original.entries.map { entry in
                guard case .external = entry.source,
                      let url = urls[entry.id] else { return entry }
                var frozen = entry
                frozen.source = .external(absolutePath: url.path)
                return frozen
            }
            return manifest
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    enum PathState: Equatable, Sendable, Codable {
        case absent
        case file(sha256: String, byteCount: Int)
        case directory(sha256: String)

        var exists: Bool { self != .absent }
        var isDirectory: Bool {
            if case .directory = self { return true }
            return false
        }
        var digest: String? {
            switch self {
            case .absent: nil
            case .file(let sha256, _), .directory(let sha256): sha256
            }
        }
        static func capture(
            _ url: URL,
            excluding exclusions: Set<String> = [],
            excludingWorkingCopyRuntime: Bool = false,
            isCancelled: @Sendable () -> Bool = { false }
        ) throws -> PathState {
            if isCancelled() { throw CancellationError() }
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return .absent }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isSymbolicLink != true else {
                throw ToolError("Export paths cannot be symbolic links.")
            }
            if values.isRegularFile == true {
                return .file(
                    sha256: try sha256(of: url, isCancelled: isCancelled),
                    byteCount: values.fileSize ?? 0
                )
            }
            guard values.isDirectory == true else {
                throw ToolError("The export path is not a regular file or directory.")
            }
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                ],
                options: []
            ) else {
                throw ToolError("The export directory cannot be inspected.")
            }
            var entries: [String] = []
            for case let child as URL in enumerator {
                if isCancelled() { throw CancellationError() }
                let relative = String(child.path.dropFirst(url.path.count + 1))
                if exclusions.contains(where: {
                    relative == $0 || relative.hasPrefix($0 + "/")
                }) || (excludingWorkingCopyRuntime
                    && ProjectWorkingCopy.isPackageRuntimePath(relative)) {
                    enumerator.skipDescendants()
                    continue
                }
                let childValues = try child.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                if childValues.isSymbolicLink == true {
                    throw ToolError("Export directories cannot contain symbolic links.")
                } else if childValues.isDirectory == true {
                    entries.append("d:\(relative)")
                } else if childValues.isRegularFile == true {
                    entries.append(
                        "f:\(relative):\(childValues.fileSize ?? 0):\(try sha256(of: child, isCancelled: isCancelled))"
                    )
                } else {
                    throw ToolError("The export directory contains an unsupported item: \(relative)")
                }
            }
            return .directory(
                sha256: FileDigest.sha256(of: Data(entries.sorted().joined(separator: "\n").utf8))
            )
        }

        private static func sha256(
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
    }
}
