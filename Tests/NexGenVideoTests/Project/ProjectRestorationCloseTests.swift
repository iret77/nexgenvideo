import AppKit
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Project restoration close drain", .serialized)
@MainActor
struct ProjectRestorationCloseTests {
    @MainActor
    private final class BillingWait {
        private var continuation: CheckedContinuation<GenerationMoney?, Never>?
        private var finished = false
        private(set) var started = false

        func charge() async -> GenerationMoney? {
            started = true
            guard !finished else { return nil }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish() {
            finished = true
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }

    @Test("Close retains its working copy until the actual reconciliation task returns",
        arguments: [VideoProject.SessionPresentation.nativeWindow, .editorSession])
    func closeDrainsLateBilling(presentation: VideoProject.SessionPresentation) async throws {
        _ = NSApplication.shared
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-close-restore-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: package)
        defer { try? FileManager.default.removeItem(at: package) }
        let transaction = UUID().uuidString
        var log = GenerationLog()
        log.spendEvents = [
            .init(transactionId: transaction, kind: .reserved, model: "fixture", provider: .fal,
                transport: .api, endpoint: "fixture"),
            .init(transactionId: transaction, kind: .submitted, model: "fixture", provider: .fal,
                transport: .api, endpoint: "fixture", providerRequestId: "accepted-fixture", providerRequestResumable: true),
            .init(transactionId: transaction, kind: .settled, model: "fixture", provider: .fal,
                transport: .api, endpoint: "fixture"),
        ]
        log.stampVersion()
        let savedLog = try JSONEncoder().encode(log)
        try savedLog.write(to: package.appendingPathComponent(Project.generationLogFilename))
        let barrier = BillingWait()
        let document = try await VideoProject.load(from: package, configureEditor: { editor in
            editor.generationBatchCoordinator.catalogReadiness = {}
            editor.generationService.reconciliation = .init(providerKey: { _ in "isolated-fixture-key" },
                falCharge: { _, _, _ in await barrier.charge() })
        })
        if presentation == .nativeWindow { document.makeWindowControllers() }
        else { document.prepareEditorSession(presentation: .editorSession) }
        #expect(document.windowControllers.isEmpty == (presentation == .editorSession))
        let editor = document.editorViewModel
        let home = try #require(editor.workingRoot)
        let key = try #require(editor.openWorkingCopyKey)
        let generation = try #require(editor.openWorkingCopyGeneration)
        defer { ProjectWorkingCopy.discard(key: key, ifGeneration: generation) }
        let restoration = try #require(document.generationRestorationTask)
        do {
            for _ in 0..<400 where !barrier.started { try await Task.sleep(for: .milliseconds(5)) }
            try #require(barrier.started)
            #expect(editor.generationService.reconcilingHomes.contains(home))
            document.close()
            #expect(restoration.isCancelled)
            #expect(document.generationRestorationTask == nil && editor.workingRoot == nil)
            await editor.generationBatchCoordinator.cancelForClose().value
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(5))
                #expect(FileManager.default.fileExists(atPath: home.path))
                #expect(editor.generationService.reconcilingHomes.contains(home))
            }
            barrier.finish()
            await restoration.value
            for _ in 0..<400 where FileManager.default.fileExists(atPath: home.path) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!FileManager.default.fileExists(atPath: home.path))
            #expect(editor.generationService.reconcilingHomes.isEmpty)
            #expect(editor.generationLog == log)
            #expect(try Data(contentsOf: package.appendingPathComponent(Project.generationLogFilename)) == savedLog)
        } catch {
            barrier.finish()
            document.close()
            await restoration.value
            ProjectWorkingCopy.discard(key: key, ifGeneration: generation)
            throw error
        }
    }
}
