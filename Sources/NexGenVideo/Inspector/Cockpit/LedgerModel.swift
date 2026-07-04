import Foundation

// Mirrors `read.py "ledger"` (engine/nexgen_engine/ledger/schema.py): the Intent Ledger — the
// director's durable creative decisions per object. Keys are `<kind>:<id>` (or the `look`/`film`
// singletons); attributes carry tag/directive/source/locked. Read-only in the app; writes happen
// through the agent's MCP tools.

struct LedgerData: Decodable, Sendable, Equatable {
    var objects: [String: [String: LedgerAttribute]]

    enum CodingKeys: String, CodingKey { case objects }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objects = try c.decodeIfPresent([String: [String: LedgerAttribute]].self, forKey: .objects) ?? [:]
    }

    /// Attributes for one inspected object, stable-sorted (locked first, then by key).
    func attributes(for object: InspectedObject) -> [(key: String, attribute: LedgerAttribute)] {
        guard let ledgerKey = Self.ledgerKey(for: object), let map = objects[ledgerKey] else { return [] }
        return map.sorted {
            if $0.value.locked != $1.value.locked { return $0.value.locked }
            return $0.key < $1.key
        }
        .map { (key: $0.key, attribute: $0.value) }
    }

    static func ledgerKey(for object: InspectedObject) -> String? {
        switch object {
        case .entity(let ref): "\(ref.kind.rawValue):\(ref.id)"
        case .shot(let id): "shot:\(id)"
        case .look: "look"
        case .clip, .mediaAsset, .shotUse: nil
        }
    }
}

struct LedgerAttribute: Decodable, Sendable, Equatable {
    var tag: String
    var directive: String
    var source: String
    var locked: Bool

    enum CodingKeys: String, CodingKey { case tag, directive, source, locked }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        directive = try c.decodeIfPresent(String.self, forKey: .directive) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
}
