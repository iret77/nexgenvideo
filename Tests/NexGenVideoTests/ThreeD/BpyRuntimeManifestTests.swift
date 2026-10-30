import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing

struct BpyRuntimeManifestTests {
    private struct Manifest: Codable, Equatable {
        let sceneSHA256: String
        let objects: [[Int]]
    }

    @Test func oversizedInvalidJSONIsRejectedBeforeDecodingAndDoesNotReserveBytes() throws {
        try withDirectory { root in
            try Data(repeating: 0x78, count: 65_537).write(to: root.appendingPathComponent("manifest.json"))
            let budget = BpyManifestReadBudget(capacity: 65_537)
            #expect(throws: CocoaError(.fileReadTooLarge)) {
                _ = try BpyRuntimeManifest.decode(Manifest.self, name: "manifest.json", in: root, maximum: 65_536, budget: budget)
            }
            #expect(budget.reservedBytes == 0)
            #expect(throws: DecodingError.self) {
                _ = try BpyRuntimeManifest.decode(Manifest.self, name: "manifest.json", in: root, maximum: 65_537, budget: budget)
            }
            #expect(budget.reservedBytes == 0)
        }
    }

    @Test func readBudgetIsCheckedBeforeDecodingAndRefundedAfterSuccess() throws {
        try withDirectory { root in
            let value = Manifest(sceneSHA256: String(repeating: "a", count: 64), objects: [[1, 2], [3]])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            try Data(repeating: 0x78, count: data.count).write(to: root.appendingPathComponent("manifest.json"))
            let short = BpyManifestReadBudget(capacity: UInt64(data.count - 1))
            #expect(throws: CocoaError(.fileReadTooLarge)) {
                _ = try BpyRuntimeManifest.decode(Manifest.self, name: "manifest.json", in: root, maximum: UInt64(data.count), budget: short)
            }
            #expect(short.reservedBytes == 0)
            try data.write(to: root.appendingPathComponent("manifest.json"))
            let budget = BpyManifestReadBudget(capacity: UInt64(data.count))
            let decoded = try BpyRuntimeManifest.decode(Manifest.self, name: "manifest.json", in: root, maximum: UInt64(data.count), budget: budget)
            #expect(decoded == value)
            #expect(try encoder.encode(decoded) == data)
            #expect(budget.reservedBytes == 0)
        }
    }

    private struct FloatingManifest: Codable { let values: [Double] }

    @Test func rawWorkerManifestKeepsItsOwnOutputBoundBeforeTheEncodedAggregateGate() throws {
        try withDirectory { root in
            let raw = Data(("{\"values\":[" + Array(repeating: "1.0", count: 64).joined(separator: ",") + "]}").utf8)
            let output: UInt64 = 512, workerBytes: UInt64 = 256
            #expect(UInt64(raw.count) > output - workerBytes)
            #expect(UInt64(raw.count) <= output)
            let maximum = try #require(BpyOutputContract.verificationReadMaximum(workerFileCount: 1,
                workerBytes: workerBytes, fileLimit: 64, byteLimit: output))
            #expect(maximum == output)
            try raw.write(to: root.appendingPathComponent("manifest.json"))
            let budget = BpyManifestReadBudget(capacity: output)
            let model = try BpyRuntimeManifest.decode(FloatingManifest.self, name: "manifest.json", in: root, maximum: maximum, budget: budget)
            #expect(model.values == Array(repeating: 1, count: 64))
            let encoded = try JSONEncoder().encode(model)
            #expect(BpyOutputContract.permitsHostManifest(workerFileCount: 1, workerBytes: workerBytes,
                manifestBytes: UInt64(encoded.count), fileLimit: 64, byteLimit: output))
            try Data(repeating: 0x78, count: Int(output + 1)).write(to: root.appendingPathComponent("manifest.json"))
            #expect(throws: CocoaError(.fileReadTooLarge)) {
                _ = try BpyRuntimeManifest.decode(FloatingManifest.self, name: "manifest.json", in: root, maximum: maximum, budget: budget)
            }
            #expect(budget.reservedBytes == 0)
        }
    }

    @Test func validJSONThroughLeafOrAncestorSymlinkIsRejected() throws {
        try withDirectory { root in
            let directory = root.appendingPathComponent("real")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let data = try JSONEncoder().encode(Manifest(sceneSHA256: "candidate", objects: []))
            let target = directory.appendingPathComponent("manifest.json")
            try data.write(to: target)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("manifest.json"), withDestinationURL: target)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            let budget = BpyManifestReadBudget(capacity: 1_024)
            for location in [root, alias] {
                #expect(throws: POSIXError.self) {
                    _ = try BpyRuntimeManifest.decode(Manifest.self, name: "manifest.json", in: location, maximum: 1_024, budget: budget)
                }
            }
            #expect(budget.reservedBytes == 0)
            #expect(try BpyRuntimeManifest.decode(Manifest.self, name: "manifest.json", in: directory, maximum: 1_024, budget: budget).sceneSHA256 == "candidate")
        }
    }

    private func withDirectory(_ operation: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: try BpyRuntimePath.canonical(FileManager.default.temporaryDirectory)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }
}
