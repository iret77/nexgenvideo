import Foundation
import Testing
@testable import NexGenEngine

@Suite("Bible")
struct BibleTests {
    /// A minimal valid Bible: one Character anchored via `reference_images`,
    /// one Location anchored via `sheets`.
    static func minimalBible() throws -> Bible {
        try Bible(
            project: "basic-project",
            generated: "2026-01-01T00:00:00Z",
            generator: "bible-agent@v1",
            characters: [
                try Character(
                    id: "teacher",
                    name: "Teacher",
                    visualPrompt: "Woman in her late 30s, short brown hair, round glasses.",
                    referenceImages: ["import/characters/teacher/ref1.png"]
                )
            ],
            locations: [
                try Location(
                    id: "classroom",
                    name: "Classroom",
                    visualPrompt: "Sunlit classroom with rows of wooden desks.",
                    sheets: ["wide": "bible/sheets/classroom/wide.png"]
                )
            ]
        )
    }

    // a. Round-trip through YAMLCoding.
    @Test("round-trips a minimal Bible through YAML")
    func roundTrip() throws {
        let bible = try Self.minimalBible()
        let yaml = try YAMLCoding.encode(bible)
        let decoded = try YAMLCoding.decode(Bible.self, from: yaml)
        #expect(decoded == bible)
    }

    // b. semanticYAMLEqual against a hand-written minimal YAML doc.
    @Test("encodes semantically equal to a hand-written minimal document")
    func semanticEquality() throws {
        let bible = try Self.minimalBible()
        let encoded = try YAMLCoding.encode(bible)
        let handWritten = """
        schema: bible/v5
        project: basic-project
        generated: "2026-01-01T00:00:00Z"
        generator: bible-agent@v1
        look:
          style: ""
          palette: ""
          lighting: ""
          lens: ""
          film_stock: ""
          grain: ""
          motion_style: ""
          additional: ""
          lighting_anchor: ""
        characters:
          - id: teacher
            name: Teacher
            visual_prompt: "Woman in her late 30s, short brown hair, round glasses."
            attributes: {}
            hard_recognition_trait: ""
            reference_images:
              - import/characters/teacher/ref1.png
            sheets: {}
        ensembles: []
        props: []
        locations:
          - id: classroom
            name: Classroom
            visual_prompt: "Sunlit classroom with rows of wooden desks."
            attributes: {}
            hard_recognition_trait: ""
            reference_images: []
            sheets:
              wide: bible/sheets/classroom/wide.png
            view_purpose: {}
            floorplan: ""
            zones: []
            proportion_anchor_shot: null
            scene3d: {}
        """
        // Compare through a decode of the hand-written doc: encoder output may
        // include keys the minimal document omits (defaults) — semantic parity
        // holds at the value level, not the raw-text level.
        let reencoded = try YAMLCoding.encode(YAMLCoding.decode(Bible.self, from: handWritten))
        #expect(try YAMLCoding.semanticYAMLEqual(encoded, reencoded))
    }

    // c. schema validator: v4 and v5 both decode; v3/v6 throw.
    @Test("accepts bible/v5 and legacy bible/v4, rejects other versions")
    func schemaVersionTolerance() throws {
        for version in ["bible/v5", "bible/v4"] {
            let yaml = """
            schema: \(version)
            project: p
            generated: t
            generator: g
            characters: []
            ensembles: []
            props: []
            locations: []
            """
            _ = try YAMLCoding.decode(Bible.self, from: yaml)
        }
        for version in ["bible/v3", "bible/v6"] {
            let yaml = """
            schema: \(version)
            project: p
            generated: t
            generator: g
            """
            #expect(throws: (any Error).self) { try YAMLCoding.decode(Bible.self, from: yaml) }
        }
    }

    // d. Global id-uniqueness validator.
    @Test("throws when two entities share an id across kinds")
    func duplicateIdsAcrossKinds() throws {
        let dupeCharacter = try Character(
            id: "dup", name: "A", visualPrompt: "one", referenceImages: ["a.png"]
        )
        let dupeEnsemble = try Ensemble(
            id: "dup", name: "B", visualPrompt: "two", memberCount: 3, referenceImages: ["b.png"]
        )
        #expect(throws: (any Error).self) {
            try Bible(
                project: "p", generated: "t", generator: "g",
                characters: [dupeCharacter], ensembles: [dupeEnsemble]
            )
        }
    }

    // e. Every-visual-entity-has-anchor validator.
    @Test("happy: character, ensemble, location each with an anchor pass")
    func anchorHappyPath() throws {
        let character = try Character(
            id: "c1", name: "C", visualPrompt: "prompt", referenceImages: ["c.png"]
        )
        let ensemble = try Ensemble(
            id: "e1", name: "E", visualPrompt: "prompt", memberCount: 5, sheets: ["group_wide": "e.png"]
        )
        let location = try Location(
            id: "l1", name: "L", visualPrompt: "prompt", sheets: ["wide": "l.png"]
        )
        _ = try Bible(
            project: "p", generated: "t", generator: "g",
            characters: [character], ensembles: [ensemble], locations: [location]
        )
    }

    @Test("failing: a character with no reference_images and no sheets throws")
    func anchorMissingCharacterThrows() throws {
        let character = try Character(id: "c1", name: "C", visualPrompt: "prompt")
        #expect(throws: (any Error).self) {
            try Bible(project: "p", generated: "t", generator: "g", characters: [character])
        }
    }

    @Test("a Prop with no anchor does NOT throw — props are exempt")
    func propsExemptFromAnchorRequirement() throws {
        let prop = try Prop(id: "p1", name: "P", visualPrompt: "prompt")
        _ = try Bible(project: "p", generated: "t", generator: "g", props: [prop])
    }

    // f. Character.sheets key validator.
    @Test("Character.sheets accepts front/side/back/expression_*")
    func characterSheetKeysAccepted() throws {
        let character = try Character(
            id: "c1", name: "C", visualPrompt: "prompt",
            sheets: ["front": "f.png", "side": "s.png", "back": "b.png", "expression_happy": "h.png"]
        )
        #expect(character.sheets.count == 4)
    }

    @Test("Character.sheets rejects an unknown key")
    func characterSheetKeyRejected() {
        #expect(throws: (any Error).self) {
            try Character(id: "c1", name: "C", visualPrompt: "prompt", sheets: ["wrong_key": "x.png"])
        }
    }

    // g. Ensemble.sheets: no key restriction.
    @Test("Ensemble.sheets accepts arbitrary keys")
    func ensembleSheetKeysUnrestricted() throws {
        let ensemble = try Ensemble(
            id: "e1", name: "E", visualPrompt: "prompt", memberCount: 4,
            sheets: ["group_wide": "gw.png"]
        )
        #expect(ensemble.sheets["group_wide"] == "gw.png")
    }

    // h. Zone.id / _IdBase.id validators.
    @Test("Zone.id accepts alnum/underscore")
    func zoneIdHappyPath() throws {
        let zone = try Zone(id: "left_window", description: "d", status: .clean)
        #expect(zone.id == "left_window")
    }

    @Test("Zone.id rejects an empty id")
    func zoneIdEmptyRejected() {
        #expect(throws: (any Error).self) {
            try Zone(id: "", description: "d", status: .clean)
        }
    }

    @Test("_IdBase.id rejects a hyphen or space")
    func idBaseRejectsHyphenOrSpace() {
        #expect(throws: (any Error).self) {
            try Character(id: "bad-id", name: "C", visualPrompt: "prompt")
        }
        #expect(throws: (any Error).self) {
            try Character(id: "bad id", name: "C", visualPrompt: "prompt")
        }
    }

    // i. Ensemble.member_count > 0.
    @Test("Ensemble.member_count rejects zero or negative")
    func ensembleMemberCountValidation() {
        #expect(throws: (any Error).self) {
            try Ensemble(id: "e1", name: "E", visualPrompt: "prompt", memberCount: 0)
        }
        #expect(throws: (any Error).self) {
            try Ensemble(id: "e1", name: "E", visualPrompt: "prompt", memberCount: -1)
        }
    }

    // j. lookupId().
    @Test("lookupId finds each kind by id and returns nil for an unknown id")
    func lookupIdFindsEachKind() throws {
        let character = try Character(
            id: "c1", name: "C", visualPrompt: "prompt", referenceImages: ["c.png"]
        )
        let ensemble = try Ensemble(
            id: "e1", name: "E", visualPrompt: "prompt", memberCount: 2, referenceImages: ["e.png"]
        )
        let prop = try Prop(id: "p1", name: "P", visualPrompt: "prompt")
        let location = try Location(
            id: "l1", name: "L", visualPrompt: "prompt", referenceImages: ["l.png"]
        )
        let bible = try Bible(
            project: "p", generated: "t", generator: "g",
            characters: [character], ensembles: [ensemble], props: [prop], locations: [location]
        )

        #expect(bible.lookupId("c1") == .character(character))
        #expect(bible.lookupId("e1") == .ensemble(ensemble))
        #expect(bible.lookupId("p1") == .prop(prop))
        #expect(bible.lookupId("l1") == .location(location))
        #expect(bible.lookupId("unknown") == nil)
    }
}
