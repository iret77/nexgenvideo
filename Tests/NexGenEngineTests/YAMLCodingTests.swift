import Foundation
import Testing
@testable import NexGenEngine

@Suite("YAMLCoding")
struct YAMLCodingTests {
    struct Sample: Codable, Equatable {
        var project: String
        var mode: String
        var budget: Double
        var tags: [String]
        var nested: Nested

        struct Nested: Codable, Equatable {
            var a: Int
            var b: String?
        }
    }

    @Test("Codable round-trips through YAML")
    func roundTrip() throws {
        let value = Sample(
            project: "basic-project", mode: "beat", budget: 50.0,
            tags: ["warm", "amber"], nested: .init(a: 1, b: "x")
        )
        let yaml = try YAMLCoding.encode(value)
        let decoded = try YAMLCoding.decode(Sample.self, from: yaml)
        #expect(decoded == value)
    }

    @Test("semanticYAMLEqual is key-order independent")
    func keyOrderIndependent() throws {
        let a = """
        project: basic-project
        mode: beat
        budget: 50.0
        nested:
          a: 1
          b: x
        """
        let b = """
        mode: beat
        nested:
          b: x
          a: 1
        budget: 50.0
        project: basic-project
        """
        #expect(try YAMLCoding.semanticYAMLEqual(a, b))
    }

    @Test("semanticYAMLEqual distinguishes different values")
    func differingValuesNotEqual() throws {
        let a = "project: one\nmode: beat\n"
        let b = "project: two\nmode: beat\n"
        #expect(try YAMLCoding.semanticYAMLEqual(a, b) == false)
    }

    @Test("null and empty scalars canonicalize alike")
    func nullNormalization() throws {
        let a = "notes: null\nproject: p\n"
        let b = "project: p\nnotes:\n"
        #expect(try YAMLCoding.semanticYAMLEqual(a, b))
    }

    @Test("an encoded value equals the source semantically")
    func encodeMatchesSource() throws {
        let value = Sample(
            project: "p", mode: "beat", budget: 12.5, tags: ["one"], nested: .init(a: 3, b: "y")
        )
        let encoded = try YAMLCoding.encode(value)
        let source = """
        nested:
          b: y
          a: 3
        tags:
          - one
        budget: 12.5
        mode: beat
        project: p
        """
        #expect(try YAMLCoding.semanticYAMLEqual(encoded, source))
    }
}
