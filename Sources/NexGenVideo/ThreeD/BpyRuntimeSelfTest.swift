import AppKit
import BpyRuntimeProtocol
import Darwin
import Foundation
import NexGenEngine

@MainActor
enum BpyRuntimeSelfTest {
    private static var pendingResult: [String: Any]?
    private static var outputDirectory: URL?
    private static var terminationOperation: BpyRuntimeOperation?

    static func scheduleIfRequested() {
        guard let outputPath = ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"],
              !outputPath.isEmpty else {
            return
        }
        Task { @MainActor in
            do {
                let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: output,
                    withIntermediateDirectories: true
                )
                outputDirectory = output
                switch ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY_SCOPE"] {
                case "scene-history":
                    pendingResult = try await runSceneHistory(output: output)
                case "scene-editing":
                    pendingResult = try await runSceneEditing(output: output)
                default:
                    throw GateBlocked("Unknown scene acceptance scope.")
                }
                AppTermination.request()
            } catch {
                recordInspectionFailureDiagnostic()
                if let outputDirectory {
                    do {
                        var diagnostic = try BpyRuntimeObservation.shared.diagnosticSnapshot()
                        diagnostic["hostPID"] = getpid()
                        diagnostic["sourceSHA"] = Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? ""
                        diagnostic["error"] = error.localizedDescription
                        try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
                            .write(to: outputDirectory.appendingPathComponent("runtime-failure-observation.json"), options: .atomic)
                    } catch {
                        FileHandle.standardError.write(Data("SELFTEST_BPY_DIAGNOSTIC_FAIL \(error.localizedDescription)\n".utf8))
                    }
                }
                let message = "SELFTEST_BPY_FAIL \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
                Darwin.exit(1)
            }
        }
    }

    private static func recordInspectionFailureDiagnostic() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              let path = environment["NGV_BPY_COMMAND_EVIDENCE"], !path.isEmpty else { return }
        do {
            var record = try BpyRuntimeObservation.shared.inspectionFailureSnapshot()
            record["hostPID"] = getpid()
            record["sourceSHA"] = Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? ""
            let url = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("host-inspection-failures-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                .write(to: url, options: .withoutOverwriting)
        } catch {
            FileHandle.standardError.write(Data("SELFTEST_BPY_INSPECTION_DIAGNOSTIC_FAIL \(error.localizedDescription)\n".utf8))
        }
    }

    static func applicationWillTerminate() {
        guard var result = pendingResult, let outputDirectory else { return }
        guard !BpyRuntimeHost.shared.hasReservedSlots else {
            FileHandle.standardError.write(Data("SELFTEST_BPY_FAIL Runtime storage survived AppDelegate shutdown.\n".utf8))
            return
        }
        guard let terminationOperation, !BpyRuntimeHost.shared.isOperationActive(terminationOperation) else {
            FileHandle.standardError.write(Data("SELFTEST_BPY_FAIL A document operation survived AppDelegate shutdown.\n".utf8))
            return
        }
        result["operationShutdown"] = true
        result["appDelegateShutdown"] = true
        result["hostPeakMemoryBytes"] = hostPeakMemoryBytes()
        do {
            result["runtimeObservation"] = try BpyRuntimeObservation.shared.evidence()
            let data = try JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(
                to: outputDirectory.appendingPathComponent("result.json"),
                options: .atomic
            )
            let marker = result["scope"] as? String == "scene-editing" ? "SELFTEST_BPY_EDITING_OK\n" : "SELFTEST_BPY_HISTORY_OK\n"
            FileHandle.standardOutput.write(Data(marker.utf8))
        } catch {
            let message = "SELFTEST_BPY_FAIL \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    private static func runSceneHistory(output: URL) async throws -> [String: Any] {
        var opened: ProductionPlanningAcceptanceFixture.Context?
        var history: [String: Any] = [:]
        defer { opened?.document.close() }
        _ = try await ProductionPlanningAcceptanceFixture.makeScript { context in
            opened = context
            NSDocumentController.shared.addDocument(context.document)
            history = try await ProductionSpatialHistoryAcceptance.run(context: context, output: output)
            guard let key = context.editor.openWorkingCopyKey else { throw SpatialSceneError.changed }
            terminationOperation = try await BpyRuntimeHost.shared.acquireOperation(document: context.document, documentID: key)
        }
        return ["schema": "nexgenvideo/scene-history-runtime/1", "scope": "scene-history",
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "",
            "historyAdmission": history]
    }

    private static func runSceneEditing(output: URL) async throws -> [String: Any] {
        var opened: ProductionPlanningAcceptanceFixture.Context?
        var selection: (SpatialSceneHead, [[String: Any]])?
        defer { opened?.document.close() }
        let context = try await ProductionPlanningAcceptanceFixture.makeScript(beforeDesignApproval: { context in
            opened = context
            NSDocumentController.shared.addDocument(context.document)
            selection = try await ProductionSceneUIAcceptance.run(context: context, output: output)
        })
        guard let (scene, sceneUI) = selection,
              let camera = try SpatialSceneStore.load(scene, in: context.dataRoot).snapshot.cameras.first else {
            throw GateBlocked("The edited scene has no saved camera.")
        }
        try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
        _ = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: context)
        let board = try await ProductionPlanningAcceptanceFixture.attachSketches(in: context)
        guard let shot = board.timing.shots.first else { throw GateBlocked("The storyboard has no planned shot.") }
        try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: context)
        _ = try await ProductionPlanningAcceptanceFixture.writeShotPlanning(in: context)
        let poseUI = try await ProductionSpatialPoseAcceptance.run(context: context, scene: scene,
            cameraID: camera.id, shotID: shot.id, output: output)
        let clayUI = try await ProductionSpatialClayAcceptance.run(context: context, shotID: shot.id, output: output)
        guard let key = context.editor.openWorkingCopyKey else { throw SpatialSceneError.changed }
        terminationOperation = try await BpyRuntimeHost.shared.acquireOperation(document: context.document, documentID: key)
        return ["schema": "nexgenvideo/scene-editing-runtime/1", "scope": "scene-editing",
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "",
            "hostPID": getpid(), "nativeSceneUI": sceneUI, "nativePoseUI": poseUI, "nativeClayUI": clayUI]
    }

    private static func hostPeakMemoryBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Int64(usage.ru_maxrss)
    }
}
