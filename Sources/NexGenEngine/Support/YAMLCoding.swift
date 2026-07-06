import Foundation
import Yams

/// YAML load/decode/encode on top of Yams, plus a key-order-independent
/// semantic comparison used by the parity tests. The Python engine writes YAML
/// with `sort_keys=False`, so byte equality is not meaningful across a
/// round-trip — structural equality is.
public enum YAMLCoding {
    public enum Error: Swift.Error, Sendable {
        case notFound(URL)
    }

    /// Decode a `Codable` value from a YAML string.
    public static func decode<T: Decodable>(_ type: T.Type, from yaml: String) throws -> T {
        try YAMLDecoder().decode(type, from: yaml)
    }

    /// Decode a `Codable` value from a YAML file.
    public static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Error.notFound(url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try decode(type, from: text)
    }

    /// Encode a `Codable` value to a YAML string.
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        try YAMLEncoder().encode(value)
    }

    /// Parse a YAML string into the canonical, comparable value tree. `nil` for
    /// an empty document (Yams returns no node).
    public static func canonical(_ yaml: String) throws -> YAMLValue? {
        guard let node = try Yams.compose(yaml: yaml) else { return nil }
        return YAMLValue(node)
    }

    /// True when two YAML documents describe the same structure regardless of
    /// mapping key order. Scalars are normalized so `"1"` and `1` compare by
    /// their canonical representation, matching how a round-trip may re-tag them.
    public static func semanticYAMLEqual(_ lhs: String, _ rhs: String) throws -> Bool {
        try canonical(lhs) == canonical(rhs)
    }
}

/// A YAML document reduced to a comparable, order-normalized value tree.
/// Mappings compare independent of key order; scalars compare by their string
/// form so representation differences (quoting, `null` vs empty) don't matter.
public enum YAMLValue: Equatable, Sendable {
    case null
    case scalar(String)
    case sequence([YAMLValue])
    case mapping([String: YAMLValue])

    init(_ node: Node) {
        switch node {
        case .scalar(let scalar):
            // Yams marks an explicit null with the `!!null` tag; a plain empty
            // scalar is also null. Everything else compares by its string value.
            if scalar.string.isEmpty || scalar.tag == Tag(Tag.Name.null) {
                self = .null
            } else {
                self = .scalar(scalar.string)
            }
        case .sequence(let sequence):
            self = .sequence(sequence.map { YAMLValue($0) })
        case .mapping(let mapping):
            var out: [String: YAMLValue] = [:]
            for (key, value) in mapping {
                out[Self.keyString(key)] = YAMLValue(value)
            }
            self = .mapping(out)
        case .alias:
            // Engine YAML never emits anchors/aliases; fold the resolved node
            // to its string form so the value stays comparable rather than dropped.
            self = .scalar(node.string ?? "")
        }
    }

    private static func keyString(_ node: Node) -> String {
        if case .scalar(let scalar) = node { return scalar.string }
        return node.string ?? ""
    }
}
