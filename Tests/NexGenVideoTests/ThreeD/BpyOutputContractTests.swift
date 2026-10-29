import BpyRuntimeProtocol
import Testing

@Suite("Actual Bpy output transfer names and complete manifest budget")
struct BpyOutputContractTests {
    @Test func hostRejectsMalformedDescriptorsBeforeAllocatingOrConvertingByteCounts() {
        func descriptor(_ name: String, bytes: UInt64 = 4, type: String = "application/json") -> BpyOutputDescriptor {
            .init(name: name, byteCount: bytes, sha256: String(repeating: "0", count: 64), mediaType: type)
        }
        let scene = descriptor("scene.blend", type: "application/x-blender")
        let proof = descriptor("verification.json")
        #expect(BpyOutputContract.acceptsOutputs([scene, proof], fileLimit: 2, byteLimit: 8))
        for outputs in [[scene], [proof], [scene, proof, descriptor("foo.part")],
                        [scene, descriptor("verification.json", bytes: UInt64.max)],
                        [scene, descriptor("verification.json", type: "image/png")]] {
            #expect(!BpyOutputContract.acceptsOutputs(outputs, fileLimit: 256, byteLimit: UInt64.max))
        }
        #expect(!BpyOutputContract.acceptsOutputs([scene, proof], fileLimit: 1, byteLimit: 8))
        #expect(!BpyOutputContract.acceptsOutputs([scene, proof], fileLimit: 2, byteLimit: 7))
        for (name, type) in [("json", "application/json"), ("png", "image/png"),
                             ("blend", "application/x-blender"), ("extra.json.", "application/json")] {
            #expect(!BpyOutputContract.acceptsOutputs([scene, proof, descriptor(name, type: type)],
                fileLimit: 3, byteLimit: 12))
        }
        #expect(BpyOutputContract.acceptsOutputs([scene, proof, descriptor("Preview.PNG", type: "image/png")],
            fileLimit: 3, byteLimit: 12))
    }

    @Test func hostManifestCannotAliasGuestBytesOnCaseInsensitiveStorage() {
        #expect(BpyOutputContract.acceptsWorkerNames(["scene.blend", "Preview.PNG"]))
        #expect(!BpyOutputContract.acceptsWorkerNames(["scene.blend", "Verification.json"]))
        #expect(!BpyOutputContract.acceptsWorkerNames(["VERIFICATION.JSON"]))
        #expect(BpyOutputContract.acceptsNames(["scene.blend", "verification.json"]))
        #expect(!BpyOutputContract.acceptsNames(["Verification.json", "verification.json"]))
        #expect(!BpyOutputContract.acceptsNames(["Preview.png", "preview.PNG"]))
    }

    @Test func namesRemainSingleBoundedASCIIFiles() {
        for name in ["../scene.blend", "/scene.blend", "é.png", "e\u{301}.png", "a\0.json", "", String(repeating: "x", count: 129)] {
            #expect(!BpyOutputContract.acceptsNames([name]))
        }
        #expect(BpyOutputContract.acceptsNames([String(repeating: "x", count: 128)]))
    }

    @Test func completeOutputIncludesNativeManifestAtBothLimits() {
        #expect(BpyOutputContract.permitsHostManifest(workerFileCount: 1, workerBytes: 90, manifestBytes: 10, fileLimit: 2, byteLimit: 100))
        #expect(!BpyOutputContract.permitsHostManifest(workerFileCount: 2, workerBytes: 90, manifestBytes: 10, fileLimit: 2, byteLimit: 100))
        #expect(!BpyOutputContract.permitsHostManifest(workerFileCount: 1, workerBytes: 91, manifestBytes: 10, fileLimit: 2, byteLimit: 100))
        #expect(!BpyOutputContract.permitsHostManifest(workerFileCount: 1, workerBytes: 101, manifestBytes: 0, fileLimit: 2, byteLimit: 100))
        #expect(!BpyOutputContract.permitsHostManifest(workerFileCount: 256, workerBytes: 0, manifestBytes: 1, fileLimit: 1_024, byteLimit: 100))
    }
}
