import BpyRuntimeProtocol
import Foundation
import Testing

@Suite("Bpy unambiguous request binding")
struct BpyJobFingerprintTests {
    @Test func optionPresenceAndArrayBoundariesAreBound() {
        #expect(digest(revision: nil) != digest(revision: "<nil>"))
        let input = BpyJobFingerprintV5.Input(name: "x", byteCount: 3, sha256: "abc")
        #expect(digest(inputs: [input]) != digest(denied: ["x", "3", "abc"]))
        #expect(digest(denied: ["/a", "/b"]) != digest(denied: ["/b", "/a"]))
        #expect(digest(source: "a") != digest(source: "a\n"))
    }

    @Test func blendHeaderSupportsPinnedZstdAndRawButRejectsOtherData() {
        #expect(BpyBlendFileFormat.accepts(Data("BLENDER-v501".utf8)))
        #expect(BpyBlendFileFormat.accepts(Data([0x28, 0xb5, 0x2f, 0xfd, 0])))
        #expect(!BpyBlendFileFormat.accepts(Data([0x28, 0xb5, 0x2f])))
        #expect(!BpyBlendFileFormat.accepts(Data("not a blend".utf8)))
    }

    @Test func admittedInputsMustFitTheDeclaredStorageBudget() {
        var limits = BpyRuntimeLimits()
        limits.diskBytes = 1_024 * 1_024
        limits.outputBytes = 1_024 * 1_024
        #expect(!limits.isValid)
        limits.inputBytes = 1_024 * 1_024
        #expect(limits.isValid)
    }

    private func digest(revision: String? = nil, source: String = "pass", inputs: [BpyJobFingerprintV5.Input] = [], denied: [String] = []) -> String {
        BpyJobFingerprintV5.compute(expectedRevision: revision, source: source, requestedTimeout: nil,
            effectiveTimeout: 120, inputs: inputs, deniedPaths: denied, autoexecControl: false,
            identityWriteFailure: false, identityCaptureFailure: false)
    }
}
