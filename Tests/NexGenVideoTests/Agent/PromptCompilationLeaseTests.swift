import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

private struct PromptCompilerOperationTimeout: LocalizedError {
    var errorDescription: String? { "The prompt compiler operation exceeded its 120-second time limit." }
}

@MainActor
func withPromptCompilerTimeLimit<Value: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        // The structured scope joins both children after cancellation.
        defer { group.cancelAll() }
        group.addTask { @MainActor in return try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(120))
            Issue.record("The prompt compiler operation exceeded its 120-second time limit.")
            throw PromptCompilerOperationTimeout()
        }
        guard let value = try await group.next() else { throw CancellationError() }
        return value
    }
}

@MainActor
@Suite("Prompt compilation publication owns the pipeline", .serialized)
struct PromptCompilationLeaseTests {
    @MainActor private final class PublicationBarrier {
        private let entered: AsyncStream<Void>
        private let entry: AsyncStream<Void>.Continuation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        init() {
            let pair = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            entered = pair.stream
            entry = pair.continuation
        }

        func pause() async {
            entry.yield(())
            if !released { await withCheckedContinuation { continuation = $0 } }
        }

        func waitUntilEntered() async -> Bool {
            var iterator = entered.makeAsyncIterator()
            return await iterator.next() != nil
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }

        func finish() { entry.finish() }
    }

    private func files(_ root: URL) throws -> [String: Data] {
        let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        return try Dictionary(uniqueKeysWithValues: paths.filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.map { (String($0.path.dropFirst(root.path.count + 1)), try Data(contentsOf: $0)) })
    }

    private func compiler(_ editor: EditorViewModel) throws -> (ToolExecutor, String) {
        let entry = try #require(ModelCatalog.launchEntries.first { $0.kind == .image })
        let catalog = ModelCatalog()
        catalog.load(entries: [entry])
        let model = try #require(catalog.image.first)
        return (ToolExecutor(editor: editor, modelCatalog: catalog), model.id)
    }

    @Test("A suspended real compiler excludes review preparation and its record survives the later root swap")
    func suspendedCompilerKeepsItsPublishedRecord() async throws {
        var retained: (path: String, bytes: Data)?
        let context = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly(beforeRenderReview: { context in
            let editor = context.editor, root = context.dataRoot
            retained = try await withPromptCompilerTimeLimit {
                let (executor, model) = try compiler(editor)
                let barrier = PublicationBarrier()
                executor.promptCompilationCheckpoint = { await barrier.pause() }
                let before = try files(root)
                let operation = Task { @MainActor in
                    defer { barrier.finish() }
                    return await executor.execute(name: "compile_prompt", args: [
                        "intent": "A green triangle on an empty white surface.", "model": model, "shotId": "none",
                    ])
                }
                defer { barrier.release(); operation.cancel() }
                do {
                    try #require(await barrier.waitUntilEntered(), "The actual compiler did not reach its publication checkpoint.")
                    #expect(editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == "render_review")
                    #expect(try files(root) == before)

                    do {
                        _ = try await PipelineRenderReviewWriter.capture(editor: editor)
                        Issue.record("Review preparation entered while the actual compiler was suspended.")
                    } catch let error as GateBlocked {
                        #expect(error.message == "Wait for the current production job before preparing the review.")
                    }
                    let (competingExecutor, _) = try compiler(editor)
                    let competing = await competingExecutor.execute(name: "compile_prompt", args: [
                        "intent": "A yellow square on a black surface.", "model": model, "shotId": "none",
                    ])
                    #expect(competing.isError)
                    #expect(ToolHarness.textOf(competing).contains("while render_review is running"))
                    #expect(try files(root) == before)

                    barrier.release()
                    let result = await operation.value
                    try #require(!result.isError, "Actual compilation: \(ToolHarness.textOf(result))")
                    #expect(editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil)
                    let payload = try #require(JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8)) as? [String: Any])
                    let text = try #require(payload["compiledPrompt"] as? String)
                    let token = try #require(payload["compileToken"] as? String)
                    let after = try files(root)
                    let newPaths = Set(after.keys).subtracting(before.keys)
                    let path = try #require(newPaths.first)
                    #expect(newPaths.count == 1)
                    #expect(path.hasPrefix("execution/compiled-prompts/"))
                    for (path, bytes) in before { #expect(after[path] == bytes) }
                    let bytes = try #require(after[path])
                    let record = try JSONDecoder().decode(ProductionCompiledPromptStore.Record.self, from: bytes)
                    #expect(record.text == text)
                    #expect(record.modelID == model)
                    #expect(record.modality == "image")
                    #expect(record.shotID == "none")
                    #expect(record.binding.promptIRSHA256 == FileDigest.sha256(of: record.sourceIR))
                    #expect(PromptCompiler.validate(token: token, text: text, modelId: model, binding: record.binding))
                    #expect(try ProductionCompiledPromptStore.path(binding: record.binding, modelID: model, text: text) == path)
                    let reference = try PlanningWriterIO.reference(path, id: "actual-compiler", role: "host.production-compiled-prompt", dataRoot: root)
                    #expect(try ProductionCompiledPromptStore.load(reference, dataRoot: root) == record)
                    return (path: path, bytes: bytes)
                } catch {
                    barrier.release()
                    operation.cancel()
                    _ = await operation.value
                    throw error
                }
            }
        })
        defer { context.document.close() }
        let record = try #require(retained)
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(record.path)) == record.bytes)
        _ = try PipelineProductionAssemblyWriter.requireCurrent(dataRoot: context.dataRoot)
    }

    @Test("Cancellation before real compiler publication releases the lease without writing")
    func cancellationReleasesWithoutPublishing() async throws {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { context.document.close() }
        try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
        let editor = context.editor, root = context.dataRoot
        try await withPromptCompilerTimeLimit {
            let (executor, model) = try compiler(editor)
            let barrier = PublicationBarrier()
            executor.promptCompilationCheckpoint = { await barrier.pause() }
            let before = try files(root)
            let operation = Task { @MainActor in
                defer { barrier.finish() }
                return await executor.execute(name: "compile_prompt", args: [
                    "intent": "A green triangle on an empty white surface.", "model": model, "shotId": "none",
                ])
            }
            defer { barrier.release(); operation.cancel() }
            do {
                try #require(await barrier.waitUntilEntered(), "The actual compiler did not reach its publication checkpoint.")
                #expect(editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == "storyboard")
                operation.cancel()
                barrier.release()
                let canceled = await operation.value
                #expect(canceled.isError)
                #expect(editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil)
                #expect(try files(root) == before)
                executor.promptCompilationCheckpoint = nil
                let retry = await executor.execute(name: "compile_prompt", args: [
                    "intent": "A green triangle on an empty white surface.", "model": model, "shotId": "none",
                ])
                #expect(!retry.isError, "Actual compilation retry: \(ToolHarness.textOf(retry))")
                #expect(editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil)
                #expect(try files(root).count == before.count + 1)
            } catch {
                barrier.release()
                operation.cancel()
                _ = await operation.value
                throw error
            }
        }
    }
}
