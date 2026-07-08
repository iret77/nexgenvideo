import Foundation

/// The Intent Ledger: durable creative memory on objects. Each addressable
/// object (a Bible entity, a shot, or the look/film singletons) carries named
/// attributes with three layers — tag (visible handle), directive (model-ready
/// phrasing), source (provenance). `locked` attributes are facts generation
/// must honor. Lives at `<data-root>/ledger.yaml`, deliberately outside the
/// Bible so regenerating the Bible never wipes director decisions.
/// Port of `ledger/schema.py`.
public let ledgerSchemaVersion = "ledger/v1"

/// Port of `ledger/schema.py::ENTITY_KINDS` / `SINGLETON_KINDS` / `OBJECT_KINDS`,
/// modeled as an enum (rather than string kind params) for type safety at the
/// Swift call sites.
public enum LedgerObjectKind: String, Sendable, CaseIterable {
    case character
    case ensemble
    case prop
    case location
    case shot
    case look
    case film

    public var isSingleton: Bool {
        switch self {
        case .look, .film: return true
        case .character, .ensemble, .prop, .location, .shot: return false
        }
    }
}

/// Port of `ledger/schema.py::Attribute`.
public struct Attribute: Codable, Sendable, Equatable {
    public var tag: String
    public var directive: String
    public var source: String
    public var locked: Bool
    public var updated: String

    public init(
        tag: String, directive: String = "", source: String = "", locked: Bool = false,
        updated: String = ""
    ) {
        self.tag = tag
        self.directive = directive
        self.source = source
        self.locked = locked
        self.updated = updated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        directive = try container.decodeIfPresent(String.self, forKey: .directive) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        updated = try container.decodeIfPresent(String.self, forKey: .updated) ?? ""
    }
}

/// Port of `ledger/schema.py::Ledger`. `objects` outer key is the object_key
/// string (e.g. `"look"` or `"character:alex"`); inner key is the attribute name.
public struct Ledger: Codable, Sendable, Equatable {
    public var schema_: String
    public var objects: [String: [String: Attribute]]

    private enum CodingKeys: String, CodingKey {
        case schema_ = "schema"
        case objects
    }

    public init(schema_: String = ledgerSchemaVersion, objects: [String: [String: Attribute]] = [:]) {
        self.schema_ = schema_
        self.objects = objects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema_ = try container.decodeIfPresent(String.self, forKey: .schema_) ?? ledgerSchemaVersion
        objects = try container.decodeIfPresent([String: [String: Attribute]].self, forKey: .objects) ?? [:]
    }
}

public enum LedgerError: Swift.Error, Sendable, Equatable {
    case missingObjectId(LedgerObjectKind)
    case emptyKey
    case emptyTag
    case attributeNotFound(object: String, key: String)
    case attributeLocked(object: String, key: String)
}

/// Port of `ledger/schema.py::object_key`. Singleton kinds return the bare
/// kind string; entity kinds require a non-empty `objectId`.
public func objectKey(kind: LedgerObjectKind, objectId: String? = nil) throws -> String {
    if kind.isSingleton {
        return kind.rawValue
    }
    guard let objectId, !objectId.isEmpty else {
        throw LedgerError.missingObjectId(kind)
    }
    return "\(kind.rawValue):\(objectId)"
}

/// UTC timestamp matching Python ledger's `_now()`: literal `Z` suffix, second
/// precision (`strftime("%Y-%m-%dT%H:%M:%SZ")`) — distinct from Gates.swift's
/// `currentTimestamp()`, which produces a `+00:00` offset suffix instead.
public func ledgerNow() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date())
}

/// Port of `ledger/schema.py::set_attribute`. Creates or updates (reconciles,
/// not appends) one attribute. An existing lock survives an update unless
/// `locked` is passed explicitly.
@discardableResult
public func setAttribute(
    _ ledger: inout Ledger, kind: LedgerObjectKind, objectId: String? = nil, key: String, tag: String,
    directive: String = "", source: String = "", locked: Bool? = nil, now: () -> String = ledgerNow
) throws -> Attribute {
    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerError.emptyKey }
    let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTag.isEmpty else { throw LedgerError.emptyTag }

    let objKey = try objectKey(kind: kind, objectId: objectId)
    var attributes = ledger.objects[objKey] ?? [:]
    let existing = attributes[key]

    let trimmedDirective = directive.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)

    let attribute = Attribute(
        tag: trimmedTag,
        directive: trimmedDirective.isEmpty ? trimmedTag : trimmedDirective,
        source: trimmedSource.isEmpty ? (existing?.source ?? "") : trimmedSource,
        locked: locked ?? (existing?.locked ?? false),
        updated: now()
    )
    attributes[key] = attribute
    ledger.objects[objKey] = attributes
    return attribute
}

/// Port of `ledger/schema.py::set_locked`. Throws if the attribute doesn't exist.
@discardableResult
public func setLocked(
    _ ledger: inout Ledger, kind: LedgerObjectKind, objectId: String? = nil, key: String, locked: Bool,
    now: () -> String = ledgerNow
) throws -> Attribute {
    let objKey = try objectKey(kind: kind, objectId: objectId)
    guard var attribute = ledger.objects[objKey]?[key] else {
        throw LedgerError.attributeNotFound(object: objKey, key: key)
    }
    attribute.locked = locked
    attribute.updated = now()
    ledger.objects[objKey]?[key] = attribute
    return attribute
}

/// Port of `ledger/schema.py::remove_attribute`. Throws if the attribute
/// doesn't exist, or if it is locked (must be unlocked first — the locked
/// guard: a lock is a promise). Removes the whole object entry once its last
/// attribute is removed.
public func removeAttribute(
    _ ledger: inout Ledger, kind: LedgerObjectKind, objectId: String? = nil, key: String
) throws {
    let objKey = try objectKey(kind: kind, objectId: objectId)
    guard let attribute = ledger.objects[objKey]?[key] else {
        throw LedgerError.attributeNotFound(object: objKey, key: key)
    }
    guard !attribute.locked else {
        throw LedgerError.attributeLocked(object: objKey, key: key)
    }
    ledger.objects[objKey]?.removeValue(forKey: key)
    if ledger.objects[objKey]?.isEmpty == true {
        ledger.objects.removeValue(forKey: objKey)
    }
}
