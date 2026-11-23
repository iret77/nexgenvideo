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
                guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY_SCOPE"] == "scene-history" else {
                    throw GateBlocked("Unknown scene-history acceptance scope.")
                }
                pendingResult = try await runSceneHistory(output: output)
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
            let marker = "SELFTEST_BPY_HISTORY_OK\n"
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

    private static func hostPeakMemoryBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Int64(usage.ru_maxrss)
    }
}
