import Foundation
import Testing
@testable import NexGenEngine

@Suite("Ledger")
struct LedgerTests {
    /// Locate the bundled fixture project home (`Fixtures/basic-project/`),
    /// same lookup DataRootResolverTests.swift uses.
    static func fixtureHome() throws -> URL {
        let dir = try #require(
            Bundle.module.url(forResource: "basic-project", withExtension: nil, subdirectory: "Fixtures"),
            "fixture Fixtures/basic-project not found in test bundle"
        )
        return dir
    }

    // MARK: - Round-trip

    @Test("Codable round-trips through YAML")
    func roundTrip() throws {
        var ledger = Ledger()
        ledger.objects["character:alex"] = [
            "wardrobe": Attribute(
                tag: "faded red canvas jacket", directive: "wearing a faded red canvas jacket",
                source: "director note", locked: true, updated: "2026-07-06T00:00:00Z"
            )
        ]
        let yaml = try YAMLCoding.encode(ledger)
        let decoded = try YAMLCoding.decode(Ledger.self, from: yaml)
        #expect(decoded == ledger)
    }

    // MARK: - Parity against the real fixture

    @Test("decodes the real fixture ledger.yaml with exact field values")
    func fixtureParity() throws {
        let url = try Self.fixtureHome().appendingPathComponent("pipeline/ledger.yaml")
        let ledger = try YAMLCoding.decode(Ledger.self, from: url)

        #expect(ledger.schema_ == "ledger/v1")
        let palette = try #require(ledger.objects["look"]?["palette"])
        #expect(palette.tag == "warm amber and teal")
        #expect(palette.directive == "warm amber/teal grade")
        #expect(palette.source == "director note")
        #expect(palette.locked == true)
        // The frozen golden's `updated` was a wall-clock stamp — assert the ledger
        // `_now()` format (literal-Z, second precision), not the volatile value.
        #expect(
            palette.updated.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression
            ) != nil,
            "updated \(palette.updated) is not a ledger _now() timestamp"
        )
    }

    // MARK: - objectKey()

    @Test("objectKey for a singleton kind with nil id returns the bare kind")
    func objectKeySingleton() throws {
        #expect(try objectKey(kind: .look) == "look")
    }

    @Test("objectKey for an entity kind with an id returns kind:id")
    func objectKeyEntity() throws {
        #expect(try objectKey(kind: .character, objectId: "alex") == "character:alex")
    }

    @Test("objectKey for an entity kind with a nil id throws")
    func objectKeyEntityNilIdThrows() {
        #expect(throws: LedgerError.self) {
            _ = try objectKey(kind: .character, objectId: nil)
        }
    }

    @Test("objectKey for an entity kind with an empty id throws")
    func objectKeyEntityEmptyIdThrows() {
        #expect(throws: LedgerError.self) {
            _ = try objectKey(kind: .prop, objectId: "")
        }
    }

    // MARK: - setAttribute()

    @Test("setAttribute creates a new attribute")
    func setAttributeCreates() throws {
        var ledger = Ledger()
        let attribute = try setAttribute(
            &ledger, kind: .look, key: "palette", tag: "warm amber", now: { "2026-01-01T00:00:00Z" }
        )
        #expect(attribute.tag == "warm amber")
        #expect(ledger.objects["look"]?["palette"]?.tag == "warm amber")
    }

    @Test("setAttribute update preserves existing lock when locked param is nil")
    func setAttributePreservesLockWhenNil() throws {
        var ledger = Ledger()
        _ = try setAttribute(
            &ledger, kind: .look, key: "palette", tag: "warm amber", locked: true,
            now: { "2026-01-01T00:00:00Z" }
        )
        let updated = try setAttribute(
            &ledger, kind: .look, key: "palette", tag: "cooler amber", locked: nil,
            now: { "2026-01-02T00:00:00Z" }
        )
        #expect(updated.locked == true)
    }

    @Test("setAttribute update overrides lock when locked param is explicit")
    func setAttributeOverridesLockWhenExplicit() throws {
        var ledger = Ledger()
        _ = try setAttribute(
            &ledger, kind: .look, key: "palette", tag: "warm amber", locked: true,
            now: { "2026-01-01T00:00:00Z" }
        )
        let updated = try setAttribute(
            &ledger, kind: .look, key: "palette", tag: "cooler amber", locked: false,
            now: { "2026-01-02T00:00:00Z" }
        )
        #expect(updated.locked == false)
    }

    @Test("setAttribute with empty key throws")
    func setAttributeEmptyKeyThrows() {
        var ledger = Ledger()
        #expect(throws: LedgerError.self) {
            _ = try setAttribute(&ledger, kind: .look, key: "   ", tag: "warm amber")
        }
    }

    @Test("setAttribute with empty tag throws")
    func setAttributeEmptyTagThrows() {
        var ledger = Ledger()
        #expect(throws: LedgerError.self) {
            _ = try setAttribute(&ledger, kind: .look, key: "palette", tag: "   ")
        }
    }

    @Test("setAttribute source falls back to existing source when new source is empty")
    func setAttributeSourceFallsBackToExisting() throws {
        var ledger = Ledger()
        _ = try setAttribute(
            &ledger, kind: .look, key: "palette", tag: "warm amber", source: "director note",
            now: { "2026-01-01T00:00:00Z" }
        )
        let updated = try setAttribute(
            &ledger, kind: .look, key: "palette", tag: "cooler amber", source: "  ",
            now: { "2026-01-02T00:00:00Z" }
        )
        #expect(updated.source == "director note")
    }

    @Test("setAttribute directive falls back to tag when directive is empty")
    func setAttributeDirectiveFallsBackToTag() throws {
        var ledger = Ledger()
        let attribute = try setAttribute(
            &ledger, kind: .look, key: "palette", tag: "warm amber", directive: "   ",
            now: { "2026-01-01T00:00:00Z" }
        )
        #expect(attribute.directive == "warm amber")
    }

    // MARK: - setLocked()

    @Test("setLocked throws for a nonexistent attribute")
    func setLockedThrowsForMissing() {
        var ledger = Ledger()
        #expect(throws: LedgerError.self) {
            _ = try setLocked(&ledger, kind: .look, key: "palette", locked: true)
        }
    }

    @Test("setLocked toggles the flag")
    func setLockedTogglesFlag() throws {
        var ledger = Ledger()
        _ = try setAttribute(&ledger, kind: .look, key: "palette", tag: "warm amber")
        let updated = try setLocked(&ledger, kind: .look, key: "palette", locked: true)
        #expect(updated.locked == true)
        #expect(ledger.objects["look"]?["palette"]?.locked == true)
    }

    // MARK: - removeAttribute()

    @Test("removeAttribute throws for a nonexistent attribute")
    func removeAttributeThrowsForMissing() {
        var ledger = Ledger()
        #expect(throws: LedgerError.self) {
            try removeAttribute(&ledger, kind: .look, key: "palette")
        }
    }

    @Test("removeAttribute throws when the attribute is locked (the locked guard)")
    func removeAttributeThrowsWhenLocked() throws {
        var ledger = Ledger()
        _ = try setAttribute(&ledger, kind: .look, key: "palette", tag: "warm amber", locked: true)
        #expect(throws: LedgerError.self) {
            try removeAttribute(&ledger, kind: .look, key: "palette")
        }
    }

    @Test("removeAttribute removes the key and the object entry once empty")
    func removeAttributeRemovesEmptyObject() throws {
        var ledger = Ledger()
        _ = try setAttribute(&ledger, kind: .look, key: "palette", tag: "warm amber")
        try removeAttribute(&ledger, kind: .look, key: "palette")
        #expect(ledger.objects["look"] == nil)
    }

    @Test("removeAttribute keeps sibling keys on the object entry")
    func removeAttributeKeepsSiblingKeys() throws {
        var ledger = Ledger()
        _ = try setAttribute(&ledger, kind: .look, key: "palette", tag: "warm amber")
        _ = try setAttribute(&ledger, kind: .look, key: "grain", tag: "16mm")
        try removeAttribute(&ledger, kind: .look, key: "palette")
        #expect(ledger.objects["look"]?["palette"] == nil)
        #expect(ledger.objects["look"]?["grain"]?.tag == "16mm")
    }

    // MARK: - ledgerNow() format

    @Test("ledgerNow produces a trailing Z, not +00:00")
    func ledgerNowFormat() {
        let stamp = ledgerNow()
        #expect(stamp.hasSuffix("Z"))
        #expect(!stamp.contains("+00:00"))
        #expect(stamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil)
    }
}
