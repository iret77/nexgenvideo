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
    /// an empty document. Uses `Yams.load` so scalars arrive RESOLVED (null/bool/
    /// int/double/string) — representation differences ("null" vs empty, "12.5"
    /// vs "1.25e+1") disappear before comparison.
    public static func canonical(_ yaml: String) throws -> YAMLValue? {
        guard let any = try Yams.load(yaml: yaml) else { return nil }
        return YAMLValue(any: any)
    }

    /// True when two YAML documents describe the same structure regardless of
    /// mapping key order. Scalars are normalized so `"1"` and `1` compare by
    /// their canonical representation, matching how a round-trip may re-tag them.
    public static func semanticYAMLEqual(_ lhs: String, _ rhs: String) throws -> Bool {
        try canonical(lhs) == canonical(rhs)
    }
}

/// A YAML document reduced to a comparable, order-normalized value tree built
/// from Yams' RESOLVED load output. Mappings compare independent of key order;
/// Int folds into Double so `50` and `50.0` agree across the Python/Swift seam.
public enum YAMLValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case sequence([YAMLValue])
    case mapping([String: YAMLValue])

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .number(Double(value))
        case let value as Double:
            self = .number(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .sequence(value.map { YAMLValue(any: $0) })
        case let value as [String: Any]:
            self = .mapping(value.mapValues { YAMLValue(any: $0) })
        case let value as [AnyHashable: Any]:
            var out: [String: YAMLValue] = [:]
            for (key, inner) in value { out[String(describing: key)] = YAMLValue(any: inner) }
            self = .mapping(out)
        default:
            // Rare resolved types (Date from bare timestamps) — both sides pass
            // through the same parser, so the description form stays comparable.
            self = .string(String(describing: any))
        }
    }
}
