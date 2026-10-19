import Foundation
import NexGenEngine

struct AgentReviewChildCallEvidence: Codable, Equatable, Sendable {
    let runID: UUID
    let authID: UUID
    let manifestID: String
    let pageID: String
    let kind: AgentReviewChildKind
    let originalChatID: UUID
    let projectID: String
    let projectGenerationID: UUID
    let workingCopyGeneration: UUID
    let generationID: UUID
    let bootstrapSHA256: String
    let response: AgentModelResponseEvidence
    fileprivate var liveAuthority: UUID? = nil

    private enum CodingKeys: String, CodingKey {
        case runID, authID, manifestID, pageID, kind, originalChatID, projectID
        case projectGenerationID, workingCopyGeneration, generationID, bootstrapSHA256, response
    }

    fileprivate init(request: AgentReviewChildRequest, generationID: UUID,
                     response: AgentModelResponseEvidence) {
        runID = request.runID; authID = request.authID
        manifestID = request.manifestID; pageID = request.pageID; kind = request.kind
        originalChatID = request.binding.originalChatID; projectID = request.binding.projectID
        projectGenerationID = request.binding.projectGenerationID
        workingCopyGeneration = request.binding.workingCopyGeneration
        self.generationID = generationID
        bootstrapSHA256 = FileDigest.sha256(of: Data(request.bootstrap.utf8))
        self.response = response
        liveAuthority = UUID()
    }

    func requireRecordedCall(request: AgentReviewChildRequest, toolName: String,
                             canonicalJSON: String) throws {
        guard runID == request.runID, authID == request.authID,
              manifestID == request.manifestID, pageID == request.pageID, kind == request.kind,
              originalChatID == request.binding.originalChatID, projectID == request.binding.projectID,
              projectGenerationID == request.binding.projectGenerationID,
              workingCopyGeneration == request.binding.workingCopyGeneration,
              bootstrapSHA256 == FileDigest.sha256(of: Data(request.bootstrap.utf8)),
              response.matchesHostTool(toolName), !response.messageID.isEmpty,
              !response.modelID.isEmpty, !response.toolUseID.isEmpty,
              response.toolInputSHA256 == (try AgentModelResponseEvidence.inputHash(canonicalJSON)),
              response.toolInputSHA256 == (try AgentModelResponseEvidence.inputHash(response.toolInputJSON)),
              request.modelID.map({ $0 == response.modelID }) ?? true else {
            throw ToolError("The saved review call does not match its authorized child context.")
        }
    }
}

private final class AgentReviewChildAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    func close() { lock.withLock { closed = true } }
    var isClosed: Bool { lock.withLock { closed } }
}

@MainActor
protocol AgentReviewChildRuntimeDriving: AnyObject {
    func start(request: AgentReviewChildRequest, generationID: UUID, sessionID: UUID, turnID: UUID,
               revalidate: @escaping @MainActor @Sendable () throws -> Void,
               execute: @escaping AgentRuntimeToolExecutor) async throws -> AsyncStream<AgentRuntimeEventEnvelope>
    func evidence(toolUseID: String, sessionID: UUID, turnID: UUID) async -> AgentModelResponseEvidence?
    func requireCurrent() throws
    func shutdown() async
}

@MainActor
final class AgentReviewChildRegistry {
    typealias RuntimeFactory = @MainActor @Sendable (AgentReviewChildRequest) throws -> any AgentReviewChildRuntimeDriving

    private final class Active {
        let request: AgentReviewChildRequest
        let generationID = UUID()
        let sessionID = UUID()
        let turnID = UUID()
        let runtime: any AgentReviewChildRuntimeDriving
        let admission = AgentReviewChildAdmission()
        let revalidate: @MainActor @Sendable () throws -> Void
        var cancelled = false
        var recorded = false
        var writeReturned = false
        var modelID: String?
        var calls: [AgentReviewChildCallEvidence] = []
        var results: [String: (AgentModelResponseEvidence, ToolResult)] = [:]
        var inFlight = Set<String>()
        var deliveredRead = false
        var readMessageID: String?
        var issued: [String: AgentReviewChildCallEvidence] = [:]

        init(request: AgentReviewChildRequest, runtime: any AgentReviewChildRuntimeDriving,
             revalidate: @escaping @MainActor @Sendable () throws -> Void) {
            self.request = request; self.runtime = runtime; self.revalidate = revalidate
        }
    }

    private let runtimeFactory: RuntimeFactory
    private var active: Active?
    var activeRunID: UUID? { active?.request.runID }

    init(runtimeFactory: @escaping RuntimeFactory) { self.runtimeFactory = runtimeFactory }

    func perform(_ request: AgentReviewChildRequest,
                 revalidate: @escaping @MainActor @Sendable () throws -> Void,
                 handler: @escaping AgentReviewChildToolHandler,
                 progress: @escaping @MainActor @Sendable (AgentReviewChildProgress) -> Void) async throws -> AgentReviewChildCompletion {
        try request.validate()
        guard active == nil else { throw ToolError("Another review context is still running or stopping.") }
        try revalidate()
        let job = Active(request: request, runtime: try runtimeFactory(request), revalidate: revalidate)
        let admission = job.admission
        active = job
        @MainActor @Sendable func report(_ stage: AgentReviewChildProgress.Stage) {
            progress(.init(runID: request.runID, pageID: request.pageID, kind: request.kind,
                           stage: stage, modelID: job.modelID))
        }
        report(.starting)
        return try await withTaskCancellationHandler {
        do {
            let events = try await job.runtime.start(request: request, generationID: job.generationID,
                sessionID: job.sessionID, turnID: job.turnID,
                revalidate: { [weak self, weak job] in
                    guard let self, let job else { throw CancellationError() }
                    try self.requireCurrent(job, revalidate: revalidate)
                }) { [weak self, weak job] id, name, json in
                guard let self, let job else { return .error("The review context has ended.") }
                do {
                    try self.requireCurrent(job, revalidate: revalidate)
                    guard name == AgentReviewChildRequest.readTool || name == AgentReviewChildRequest.writeTool,
                          let response = await job.runtime.evidence(toolUseID: id, sessionID: job.sessionID, turnID: job.turnID) else {
                        throw ToolError("The review tool has no current model response evidence.")
                    }
                    try self.requireCurrent(job, revalidate: revalidate)
                    guard let schema = request.hostContext.toolSchemas.first(where: { $0.name == name }) else {
                        throw ToolError("The review tool has no authorized schema.")
                    }
                    try validateToolInput(in: JSONSerialization.jsonObject(with: Data(json.utf8)),
                        against: schema.inputSchema, path: name)
                    guard response.sessionID == job.sessionID, response.turnID == job.turnID,
                          response.toolUseID == id,
                          response.toolName == (request.backend == .claudeCode ? "mcp__nexgen__\(name)" : name),
                          response.toolInputSHA256 == (try AgentModelResponseEvidence.inputHash(json)),
                          !response.modelID.isEmpty,
                          job.modelID.map({ $0 == response.modelID }) ?? true,
                          request.modelID.map({ $0 == response.modelID }) ?? true else {
                        throw ToolError("The review response model or tool binding changed.")
                    }
                    if let cached = job.results[id] {
                        guard cached.0 == response else { throw ToolError("A repeated review call changed its response evidence.") }
                        return cached.1
                    }
                    guard !job.writeReturned, !job.recorded, job.inFlight.isEmpty else {
                        throw ToolError("The review context already has a tool call in progress or has finished recording.")
                    }
                    if name == AgentReviewChildRequest.writeTool {
                        guard job.deliveredRead, let readMessageID = job.readMessageID,
                              response.messageID != readMessageID else {
                            throw ToolError("Read this review page before recording it in a later model response.")
                        }
                    }
                    job.modelID = response.modelID
                    job.inFlight.insert(id)
                    defer { job.inFlight.remove(id); job.issued[id] = nil }
                    let evidence = AgentReviewChildCallEvidence(request: request, generationID: job.generationID, response: response)
                    job.issued[id] = evidence
                    try evidence.requireRecordedCall(request: request, toolName: name, canonicalJSON: response.toolInputJSON)
                    report(name == AgentReviewChildRequest.readTool ? .reading : .recording)
                    let result: ToolResult
                    if name == AgentReviewChildRequest.readTool, job.deliveredRead {
                        result = .ok("This page has already been delivered in this child context. Review its existing inputs and record the observations.")
                    } else {
                        result = try await handler(name, response.toolInputJSON, evidence)
                    }
                    if name == AgentReviewChildRequest.writeTool, !result.isError {
                        job.writeReturned = true
                    }
                    try self.requireCurrent(job, revalidate: revalidate)
                    guard try JSONEncoder().encode(result.toMCPResult()).count <= request.bounds.maximumToolResultBytes else {
                        throw ToolError("The review result exceeds its authorized transport size.")
                    }
                    job.calls.append(evidence)
                    job.results[id] = (response, result)
                    if name == AgentReviewChildRequest.readTool, !result.isError, !job.deliveredRead {
                        job.deliveredRead = true
                        job.readMessageID = response.messageID
                    }
                    if name == AgentReviewChildRequest.writeTool, !result.isError {
                        guard result.turnDisposition == .suspendTurn else {
                            throw ToolError("The review writer did not suspend the completed child turn.")
                        }
                        job.recorded = true
                    }
                    return result
                } catch { return .error(error.localizedDescription) }
            }
            var usage = AgentRuntimeUsage()
            for await event in events {
                try requireCurrent(job, revalidate: revalidate)
                guard event.sessionID == job.sessionID, event.turnID == job.turnID else {
                    throw ToolError("A review event belongs to another child turn.")
                }
                if case .usage(let update) = event.event { usage = usage.merging(update) }
                if case .error(let error) = event.event { throw ToolError(error.message) }
                if case .terminal(.cancelled) = event.event { throw CancellationError() }
                if case .terminal(.failed) = event.event { throw ToolError("The review context failed.") }
            }
            try requireCurrent(job, revalidate: revalidate)
            guard job.recorded, let modelID = job.modelID else {
                throw ToolError("The review context ended without recording its page.")
            }
            admission.close()
            report(.stopping)
            await job.runtime.shutdown()
            try Task.checkCancellation()
            guard active === job, !job.cancelled else { throw CancellationError() }
            try revalidate()
            active = nil
            report(.completed)
            return .init(runID: request.runID, authID: request.authID, manifestID: request.manifestID,
                pageID: request.pageID, generationID: job.generationID, modelID: modelID, calls: job.calls, usage: usage)
        } catch {
            admission.close()
            report(.stopping)
            await job.runtime.shutdown()
            if active === job { active = nil }
            report(job.cancelled || error is CancellationError ? .cancelled : .failed)
            throw error
        }
        } onCancel: { admission.close() }
    }

    func cancel(runID: UUID) async {
        guard let job = active, job.request.runID == runID else { return }
        job.cancelled = true
        job.admission.close()
        await job.runtime.shutdown()
    }

    func cancelAll() async {
        guard let runID = activeRunID else { return }
        await cancel(runID: runID)
    }

    func requireCurrent(_ evidence: AgentReviewChildCallEvidence) throws {
        try Task.checkCancellation()
        guard let job = active, !job.cancelled, !job.admission.isClosed,
              job.generationID == evidence.generationID,
              job.request.runID == evidence.runID, job.request.authID == evidence.authID,
              job.request.manifestID == evidence.manifestID, job.request.pageID == evidence.pageID,
              evidence.liveAuthority != nil,
              job.inFlight.contains(evidence.response.toolUseID),
              job.issued[evidence.response.toolUseID] == evidence else {
            throw ToolError("The review child call is no longer active.")
        }
        try job.runtime.requireCurrent()
        try job.revalidate()
    }

    private func requireCurrent(_ job: Active, revalidate: @MainActor () throws -> Void) throws {
        try Task.checkCancellation()
        guard active === job, !job.cancelled, !job.admission.isClosed else { throw CancellationError() }
        try job.runtime.requireCurrent()
        try revalidate()
    }
}
