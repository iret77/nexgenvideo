import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyJSONValidationTests {
    @Test func validatesCompleteObjectsWithoutMaterializingValues() throws {
        for text in ["{}", "[]", " {\"a\":[true,false,null,-12.5e+3,0,0.125],\"b\":{}}\n",
                     #"["\"\\\/\b\f\n\r\t", "\uD83C\uDFAC", "🎬", "ä"]"#] {
            let bytes = Data(text.utf8)
            #expect((try? JSONSerialization.jsonObject(with: bytes)) != nil)
            try withFile(bytes) { try BpyJSONValidation.validate($0) }
        }
    }

    @Test func rejectsMalformedAndTruncatedDocuments() throws {
        let texts = ["", " ", "null", "1", "{}[]", "[1 2]", "[1,]", "{\"a\":}", "{a:1}",
                     "[01]", "[-]", "[1.]", "[1e]", "[1e+]", "[.1]", "[NaN]", "[Infinity]",
                     "[tru]", "[falseX]", "[nullx]", "[\"unterminated]", "[\"a\nb\"]",
                     #"["\x20"]"#, #"["\uD800"]"#, #"["\uDC00"]"#, #"["\uD800\u0041"]"#,
                     #"["\uZZZZ"]"#, "[[[]]", "{\"a\":1"]
        for text in texts {
            try withFile(Data(text.utf8)) { file in
                #expect(throws: (any Error).self) { try BpyJSONValidation.validate(file) }
            }
        }
        for invalidUTF8: [UInt8] in [[0xc0, 0xaf], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0x80], [0xe2, 0x82]] {
            try withFile(Data([0x5b, 0x22] + invalidUTF8 + [0x22, 0x5d])) { file in
                #expect(throws: (any Error).self) { try BpyJSONValidation.validate(file) }
            }
        }
    }

    @Test func unicodeEscapesAndTokensCrossReadBoundaries() throws {
        let padding = String(repeating: "a", count: 65_533)
        for suffix in ["🎬\"]", #"\uD83C\uDFAC"]"#] {
            let bytes = Data(("[\"" + padding + suffix).utf8)
            #expect((try? JSONSerialization.jsonObject(with: bytes)) != nil)
            try withFile(bytes) { try BpyJSONValidation.validate($0) }
        }
        let bytes = Data((String(repeating: " ", count: 65_534) + "[true,false,null,-2.5e-3]").utf8)
        try withFile(bytes) { try BpyJSONValidation.validate($0) }
    }

    @Test func preservesFoundationDepthBoundAndChecksCancellationDuringLargeValues() throws {
        try withFile(Data((String(repeating: "[", count: 512) + String(repeating: "]", count: 512)).utf8)) {
            try BpyJSONValidation.validate($0)
        }
        try withFile(Data((String(repeating: "[", count: 513) + String(repeating: "]", count: 513)).utf8)) { file in
            #expect(throws: (any Error).self) { try BpyJSONValidation.validate(file) }
        }
        let bytes = Data(("[\"" + String(repeating: "a", count: 131_072) + "\"]").utf8)
        try withFile(bytes) { file in
            var reads = 0
            #expect(throws: BpyAdmissionFailure.self) {
                try BpyJSONValidation.validate(file) {
                    reads += 1
                    if reads == 2 { throw BpyAdmissionFailure.cancelled }
                }
            }
            #expect(reads == 2)
        }
    }

    private func withFile(_ bytes: Data, _ body: (BpyRuntimeFile) throws -> Void) throws {
        let root = URL(fileURLWithPath: try BpyRuntimePath.canonical(FileManager.default.temporaryDirectory)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try BpyRuntimeFile.copy(data: bytes, to: root.appendingPathComponent("output.json"), maximum: UInt64(bytes.count))
        defer { file.release() }
        try body(file)
    }
}
