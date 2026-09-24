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
    let destinationURL: URL?
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
        [.pending, .preparing, .exporting].contains(status)
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
        return jobs.first { $0.ownerKey == ownerKey && $0.status == .pending }
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
        return try joinedJob(
            id: id,
            fingerprint: fingerprint(
                ownerKey, specID, String(describing: format), resolution.rawValue,
                outputURL.standardizedFileURL.path
            )
        )
    }

    func enqueueDelivery(
        editor: EditorViewModel,
        spec: DeliverySpecV1,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL,
        requestID: String? = nil
    ) throws -> ExportJob {
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
        try PipelineDeliveryStore.recoverInterruptedJobs(
            dataRoot: dataRoot,
            excludingIDs: activeDeliveryIDs(dataRoot: dataRoot),
            willMutate: { try ProjectWorkingCopy.markDirty(key: ownerKey) },
            didRecover: { cleanupTemporaryState(for: $0) }
        )
        let timeline = editor.timeline
        let resolver = editor.mediaResolver.snapshot()
        let finished = try PipelineDeliveryStore.requireCurrentFinished(
            dataRoot: dataRoot,
            timeline: timeline
        )
        try PipelineDeliveryStore.requireBoundFinished(
            dataRoot: dataRoot,
            finished: finished,
            timeline: timeline,
            resolver: resolver
        )
        let extensionFiles = try PipelineDeliveryStore.extensionFiles(
            for: spec,
            dataRoot: dataRoot
        )
        let source = try SourceBinding.video(
            timeline: timeline,
            resolver: resolver,
            additionalFiles: extensionFiles
        )
        let destination = try DestinationBinding(
            url: outputURL,
            jobID: id,
            expectsDirectory: false
        )
        try source.rejectDestination(destination.url)
        try ProjectWorkingCopy.markDirty(key: ownerKey)
        let attempt = try PipelineDeliveryStore.enqueueAttempt(
            id: id,
            dataRoot: dataRoot,
            finished: finished,
            spec: spec,
            format: format,
            resolution: resolution,
            outputURL: destination.url,
            timeline: timeline,
            resolver: resolver
        )
        let changeHandler = projectChangeHandler(
            editor: editor,
            ownerKey: ownerKey,
            root: root
        )
        let currentHandler = projectCurrentHandler(
            editor: editor,
            ownerKey: ownerKey,
            root: root,
            timelineSHA256: finished.manifest.timelineSHA256
        )
        let payload = DeliveryPayload(
            dataRoot: dataRoot,
            timeline: timeline,
            resolver: resolver,
            finished: finished,
            spec: spec,
            format: format,
            resolution: resolution,
            attempt: attempt
        )
        return register(Request(
            id: id,
            ownerKey: ownerKey,
            projectID: finished.plan.projectID,
            kind: .video,
            title: destination.url.lastPathComponent,
            durationFrames: timeline.totalFrames,
            fps: timeline.fps,
            width: timeline.width,
            height: timeline.height,
            fingerprint: fingerprint,
            source: source,
            destination: destination,
            companionDestination: nil,
            payload: .delivery(payload),
            changeHandler: changeHandler,
            currentHandler: currentHandler
        ))
    }

    func enqueueInterchange(
        editor: EditorViewModel,
        format: ExportFormat,
        outputURL: URL,
        projectName: String,
        fcpxmlVersion: FCPXMLVersion = .default,
        fcpxmlTarget: FCPXMLTarget = .default,
        requestID: String? = nil
    ) throws -> ExportJob {
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
        let source = try SourceBinding.interchange(timeline: timeline, resolver: resolver)
        let destination = try DestinationBinding(
            url: outputURL,
            jobID: id,
            expectsDirectory: false
        )
        try source.rejectDestination(destination.url)
        let payload = InterchangePayload(
            timeline: timeline,
            resolver: resolver,
            format: format,
            projectName: projectName,
            fcpxmlVersion: fcpxmlVersion,
            fcpxmlTarget: fcpxmlTarget
        )
        let companionDestination: DestinationBinding?
        if format == .fcpxml {
            companionDestination = try DestinationBinding(
                url: FCPXMLExporter.mediaDirectory(for: outputURL),
                jobID: id,
                expectsDirectory: true
            )
        } else {
            companionDestination = nil
        }
        if let companionDestination {
            try source.rejectDestination(companionDestination.url)
        }
        return register(Request(
            id: id,
            ownerKey: ownerKey,
            projectID: editor.projectId ?? ownerKey,
            kind: format == .xml ? .xml : .fcpxml,
            title: destination.url.lastPathComponent,
            durationFrames: timeline.totalFrames,
            fps: timeline.fps,
            width: timeline.width,
            height: timeline.height,
            fingerprint: fingerprint,
            source: source,
            destination: destination,
            companionDestination: companionDestination,
            payload: .interchange(payload),
            changeHandler: projectChangeHandler(editor: editor, ownerKey: ownerKey, root: root),
            currentHandler: { false }
        ))
    }

    func enqueueProjectPackage(
        editor: EditorViewModel,
        outputURL: URL,
        requestID: String? = nil
    ) throws -> ExportJob {
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
        let source = try SourceBinding.projectPackage(
            timeline: timeline,
            manifest: manifest,
            sourceRoot: root
        )
        let destination = try DestinationBinding(
            url: outputURL,
            jobID: id,
            expectsDirectory: true
        )
        try source.rejectDestination(destination.url)
        let sourcePath = root.standardizedFileURL.path
        guard destination.url.path != sourcePath,
              !destination.url.path.hasPrefix(sourcePath + "/") else {
            throw ToolError("Export the project package outside its source working copy.")
        }
        let payload = ProjectPayload(
            timeline: timeline,
            manifest: manifest,
            generationLog: generationLog,
            sourceRoot: root
        )
        return register(Request(
            id: id,
            ownerKey: ownerKey,
            projectID: editor.projectId ?? ownerKey,
            kind: .project,
            title: destination.url.lastPathComponent,
            durationFrames: timeline.totalFrames,
            fps: timeline.fps,
            width: timeline.width,
            height: timeline.height,
            fingerprint: fingerprint,
            source: source,
            destination: destination,
            companionDestination: nil,
            payload: .project(payload),
            changeHandler: projectChangeHandler(editor: editor, ownerKey: ownerKey, root: root),
            currentHandler: { false }
        ))
    }

    func cancel(jobID: String) {
        guard let job = jobsByID[jobID], job.canCancel else { return }
        cancellationRequests.insert(jobID)
        cancellationFlags[jobID]?.cancel()
        if job.status == .pending, currentID != jobID {
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
                resolver: payload.resolver
            )
            retried.payload = .delivery(payload.withAttempt(attempt))
        }
        return register(retried)
    }

    func waitForCompletion(jobID: String) async -> ExportJob? {
        while let job = jobsByID[jobID], !job.status.isTerminal {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return jobsByID[jobID]
    }

    func waitUntilIdle(ownerKey: String) async {
        while jobs.contains(where: { $0.ownerKey == ownerKey && !$0.status.isTerminal }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @discardableResult
    func loadPersistedDeliveryJobs(ownerKey: String?, dataRoot: URL?) -> Bool {
        guard let ownerKey, let dataRoot else { return false }
        var recovered = false
        do {
            recovered = try PipelineDeliveryStore.recoverInterruptedJobs(
                dataRoot: dataRoot,
                excludingIDs: activeDeliveryIDs(dataRoot: dataRoot),
                willMutate: { try ProjectWorkingCopy.markDirty(key: ownerKey) },
                didRecover: { cleanupTemporaryState(for: $0) }
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
                let job = ExportJob(
                    id: attempt.id,
                    ownerKey: ownerKey,
                    projectID: ownerKey,
                    kind: .video,
                    destinationURL: destination,
                    title: destination?.lastPathComponent ?? "Interrupted export",
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

    private func register(_ request: Request) -> ExportJob {
        let job = ExportJob(
            id: request.id,
            ownerKey: request.ownerKey,
            projectID: request.projectID,
            kind: request.kind,
            destinationURL: request.destination.url,
            title: request.title,
            durationFrames: request.durationFrames,
            fps: request.fps,
            width: request.width,
            height: request.height
        )
        jobs.append(job)
        jobsByID[job.id] = job
        requests[job.id] = request
        cancellationFlags[job.id] = ExportCancellationFlag()
        pendingIDs.append(job.id)
        startDrainIfNeeded()
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
        var frozenSources: FrozenSources?
        defer { frozenSources?.remove() }
        do {
            try throwIfCancelled(job.id)
            let cancellationFlag = cancellationFlags[job.id] ?? ExportCancellationFlag()
            try await ExportCoordinator.acquireExport(
                isCancelled: { cancellationFlag.isCancelled }
            )
            defer { ExportCoordinator.endExport() }
            try throwIfCancelled(job.id)

            job.status = .preparing
            job.detail = "Preparing"
            await Task.yield()
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
            }
            let source = request.source
            let jobID = job.id
            try await Task.detached(priority: .userInitiated) {
                try source.verify(isCancelled: { cancellationFlag.isCancelled })
            }.value
            let frozen = try await Task.detached(priority: .userInitiated) {
                try source.freeze(
                    jobID: jobID,
                    isCancelled: { cancellationFlag.isCancelled }
                )
            }.value
            frozenSources = frozen
            try throwIfCancelled(job.id)
            try await Task.detached(priority: .userInitiated) {
                try source.verify(isCancelled: { cancellationFlag.isCancelled })
                try frozen.verify(isCancelled: { cancellationFlag.isCancelled })
            }.value

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
            try throwIfCancelled(job.id)
            try await Task.detached(priority: .userInitiated) {
                try source.verify(isCancelled: { cancellationFlag.isCancelled })
                try frozen.verify(isCancelled: { cancellationFlag.isCancelled })
            }.value
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
            try DestinationBinding.publish(publications)
            published = true

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
                    selectIfCurrent: request.currentHandler()
                )
                job.outputSHA256 = result.attempt.outputSHA256
                job.outputByteCount = result.attempt.outputByteCount
                if let selectionWarning = result.selectionWarning {
                    job.warnings.append(selectionWarning)
                }
                request.changeHandler()
            case .interchange:
                let values = try request.destination.url.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                )
                guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                    throw ToolError("The exported interchange file is missing or empty.")
                }
                job.outputSHA256 = try FileDigest.sha256(of: request.destination.url)
                job.outputByteCount = Int64(size)
                job.fcpxmlReport = fcpxmlReport
                job.warnings = fcpxmlReport?.warnings.map(\.message) ?? []
            case .project:
                let state = try PathState.capture(request.destination.url)
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

    private func joinedJob(id: String, fingerprint: String) throws -> ExportJob? {
        guard let existing = jobsByID[id] else { return nil }
        guard requests[id]?.fingerprint == fingerprint else {
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

    private func activeDeliveryIDs(dataRoot: URL) -> Set<String> {
        Set(requests.compactMap { id, request in
            guard let job = jobsByID[id], !job.status.isTerminal,
                  case .delivery(let payload) = request.payload,
                  payload.dataRoot.standardizedFileURL == dataRoot.standardizedFileURL else {
                return nil
            }
            return id
        })
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
}

private extension ExportQueue {
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
        var destination: DestinationBinding
        var companionDestination: DestinationBinding?
        var payload: Payload
        let changeHandler: @MainActor () -> Void
        let currentHandler: @MainActor () -> Bool

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

        static func video(
            timeline: Timeline,
            resolver: MediaResolver,
            additionalFiles: [(path: String, url: URL)]
        ) throws -> SourceBinding {
            let tracks = timeline.tracks.filter {
                !$0.hidden && ($0.type != .audio || !$0.muted)
            }
            return try make(
                timeline: timeline,
                refs: mediaRefs(timeline.tracks),
                requiredRefs: mediaRefs(tracks),
                resolver: resolver,
                additionalFiles: additionalFiles
            )
        }

        static func interchange(timeline: Timeline, resolver: MediaResolver) throws -> SourceBinding {
            try make(
                timeline: timeline,
                refs: mediaRefs(timeline.tracks),
                requiredRefs: [],
                resolver: resolver,
                additionalFiles: []
            )
        }

        static func projectPackage(
            timeline: Timeline,
            manifest: MediaManifest,
            sourceRoot: URL
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
                additionalFiles: []
            )
            return .init(
                timelineSHA256: binding.timelineSHA256,
                media: binding.media,
                rootURL: sourceRoot,
                rootState: try PathState.capture(sourceRoot)
            )
        }

        func verify(isCancelled: @Sendable () -> Bool = { false }) throws {
            for item in media {
                if isCancelled() { throw CancellationError() }
                guard try PathState.capture(item.url, isCancelled: isCancelled) == item.state else {
                    throw ToolError("Export source changed or is offline: \(item.ref)")
                }
            }
            if let rootURL, let rootState,
               try PathState.capture(rootURL, isCancelled: isCancelled) != rootState {
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
            additionalFiles: [(path: String, url: URL)]
        ) throws -> SourceBinding {
            let timelineData = try PipelineAssemblyStore.canonical(timeline)
            var media = try refs.sorted().compactMap { ref in
                guard let url = resolver.expectedURL(for: ref) else {
                    if !requiredRefs.contains(ref) { return nil }
                    throw ToolError("Export source is unresolved: \(resolver.displayName(for: ref))")
                }
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
                let state = try PathState.capture(resolved)
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
                let resolved = item.url.standardizedFileURL.resolvingSymlinksInPath()
                let state = try PathState.capture(resolved)
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
                rootState: nil
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
                        isCancelled: isCancelled
                    )
                    guard try PathState.capture(
                        destination,
                        isCancelled: isCancelled
                    ) == rootState else {
                        throw ToolError("The project source changed while it was being frozen.")
                    }
                    frozenProjectRoot = destination
                } else {
                    frozenProjectRoot = nil
                }
                return FrozenSources(
                    root: root,
                    files: frozenFiles,
                    projectRoot: frozenProjectRoot,
                    projectState: rootState
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

        private static func mediaRefs(_ tracks: [Track]) -> Set<String> {
            Set(tracks.flatMap { track in
                track.clips.compactMap { clip in
                    clip.sourceClipType == .text ? nil : clip.mediaRef
                }
            })
        }
    }

    struct DestinationBinding {
        struct Publication {
            let binding: DestinationBinding
            let temporaryURL: URL
        }

        let url: URL
        let initialState: PathState
        let jobID: String
        let temporaryURL: URL
        let expectsDirectory: Bool

        init(url: URL, jobID: String, expectsDirectory: Bool) throws {
            let standardized = url.standardizedFileURL
            let parent = standardized.deletingLastPathComponent()
            let values = try parent.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw ToolError("The export destination directory does not exist.")
            }
            let initialState = try PathState.capture(standardized)
            guard !initialState.exists
                    || initialState.isDirectory == expectsDirectory else {
                throw ToolError("The export destination has the wrong file type.")
            }
            self.url = standardized
            self.initialState = initialState
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
                jobID: jobID,
                expectsDirectory: expectsDirectory
            )
        }

        func publish(temporaryURL: URL) throws {
            try Self.publish([.init(binding: self, temporaryURL: temporaryURL)])
        }

        static func publish(_ publications: [Publication]) throws {
            guard Set(publications.map { $0.binding.url }).count == publications.count else {
                throw ToolError("An export cannot publish two results to the same destination.")
            }
            for publication in publications {
                let binding = publication.binding
                guard try PathState.capture(binding.url) == binding.initialState else {
                    throw ToolError("The export destination changed after this job was queued.")
                }
                let temporaryValues = try publication.temporaryURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                let typeMatches = binding.expectsDirectory
                    ? temporaryValues.isDirectory == true
                    : temporaryValues.isRegularFile == true
                guard temporaryValues.isSymbolicLink != true,
                      typeMatches else {
                    throw ToolError("The export produced no temporary result.")
                }
            }

            let fm = FileManager.default
            if let publication = publications.first, publications.count == 1 {
                let binding = publication.binding
                if binding.initialState.exists {
                    _ = try fm.replaceItemAt(
                        binding.url,
                        withItemAt: publication.temporaryURL
                    )
                } else {
                    try fm.moveItem(at: publication.temporaryURL, to: binding.url)
                }
                return
            }
            var backups: [(target: URL, backup: URL)] = []
            var installed: [URL] = []
            do {
                for publication in publications {
                    let binding = publication.binding
                    if binding.initialState.exists {
                        let backup = binding.url.deletingLastPathComponent()
                            .appendingPathComponent(
                                ".\(binding.url.lastPathComponent).\(binding.jobID).backup"
                            )
                        guard !fm.fileExists(atPath: backup.path) else {
                            throw ToolError("An export backup already exists for this job and destination.")
                        }
                        try fm.moveItem(at: binding.url, to: backup)
                        backups.append((binding.url, backup))
                    }
                    try fm.moveItem(at: publication.temporaryURL, to: binding.url)
                    installed.append(binding.url)
                }
            } catch {
                let failure = error
                var rollbackFailures: [String] = []
                for target in installed.reversed() where fm.fileExists(atPath: target.path) {
                    do { try fm.removeItem(at: target) }
                    catch { rollbackFailures.append(target.lastPathComponent) }
                }
                for item in backups.reversed() where fm.fileExists(atPath: item.backup.path) {
                    do { try fm.moveItem(at: item.backup, to: item.target) }
                    catch { rollbackFailures.append(item.target.lastPathComponent) }
                }
                guard rollbackFailures.isEmpty else {
                    throw ToolError(
                        "Export publish failed and rollback could not restore: "
                            + rollbackFailures.joined(separator: ", ")
                    )
                }
                throw failure
            }
            for item in backups where fm.fileExists(atPath: item.backup.path) {
                try? fm.removeItem(at: item.backup)
            }
        }

        private init(
            url: URL,
            initialState: PathState,
            jobID: String,
            expectsDirectory: Bool
        ) {
            self.url = url
            self.initialState = initialState
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

    enum PathState: Equatable, Sendable {
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
                let childValues = try child.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                let relative = String(child.path.dropFirst(url.path.count + 1))
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
