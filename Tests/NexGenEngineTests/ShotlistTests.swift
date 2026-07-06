import Foundation
import Testing
@testable import NexGenEngine

@Suite("Shotlist")
struct ShotlistTests {
    // MARK: - Helpers

    static func song(durationS: Double = 4.0, bpm: Double = 120.0) throws -> Song {
        try Song(title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: bpm, durationS: durationS)
    }

    static func shot(
        id: String = "s001", section: String? = "verse", timeStart: Double = 0.0, timeEnd: Double = 4.0,
        durationS: Double = 4.0, cameraId: String? = nil, cameraLabel: String? = nil,
        characterRefs: [String] = [], characterBlocking: [CharacterBlocking] = []
    ) throws -> Shot {
        try Shot(
            id: id, section: section, timeStart: timeStart, timeEnd: timeEnd, durationS: durationS,
            type: .performance, description: "d", visualPrompt: "p", mood: "m",
            characterRefs: characterRefs, characterBlocking: characterBlocking,
            cameraId: cameraId, cameraLabel: cameraLabel
        )
    }

    static func shotlist(
        mode: Mode = .section, shots: [Shot]? = nil, song: Song? = nil, schema_: String = shotlistSchemaVersion
    ) throws -> Shotlist {
        try Shotlist(
            schema_: schema_, mode: mode, project: "proj",
            song: try song ?? Self.song(), generated: "2026-01-01", generator: "test",
            shots: try shots ?? [Self.shot()]
        )
    }

    // MARK: - test_shotlist_round_trip port

    @Test("shotlist round-trips through encode/decode (port of test_shotlist_round_trip)")
    func shotlistRoundTrip() throws {
        let shot = try Shot(
            id: "s001", section: "verse", timeStart: 0.0, timeEnd: 4.0, durationS: 4.0,
            type: .performance, description: "d", visualPrompt: "p", mood: "m"
        )
        let song = try Song(title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: 4.0)
        let sl = try Shotlist(
            schema_: shotlistSchemaVersion, mode: .section, project: "proj", song: song,
            generated: "2026-01-01", generator: "test", shots: [shot]
        )

        let yaml = try YAMLCoding.encode(sl)
        let again = try YAMLCoding.decode(Shotlist.self, from: yaml)

        #expect(again.shots[0].id == "s001")
        #expect(again.mode == .section)
    }

    // MARK: - source_mode (hybrid production, issue #129)

    @Test("sourceMode defaults to .generated and round-trips per mode",
          arguments: [SourceMode.generated, .imported, .aiEnhanced])
    func sourceModeRoundTrips(_ mode: SourceMode) throws {
        let shot = try Shot(
            id: "s001", section: "verse", timeStart: 0.0, timeEnd: 4.0, durationS: 4.0,
            type: .performance, sourceMode: mode, description: "d", visualPrompt: "p", mood: "m"
        )
        #expect(shot.sourceMode == mode)
        let sl = try Self.shotlist(shots: [shot])
        let again = try YAMLCoding.decode(Shotlist.self, from: try YAMLCoding.encode(sl))
        #expect(again.shots[0].sourceMode == mode)
    }

    @Test("sourceMode raw values are snake_case")
    func sourceModeRawValues() throws {
        #expect(SourceMode.generated.rawValue == "generated")
        #expect(SourceMode.imported.rawValue == "imported")
        // 0.7.0 wrote "live_action"; the alias keeps those shotlists decoding.
        let legacy = try YAMLCoding.decode(SourceMode.self, from: "live_action")
        #expect(legacy == .imported)
        #expect(SourceMode.aiEnhanced.rawValue == "ai_enhanced")
    }

    @Test("a shotlist YAML without source_mode decodes shots as .generated (default)")
    func sourceModeAbsentDefaultsToGenerated() throws {
        // A pre-#129 shotlist: no `source_mode` key anywhere. Every shot must default to generated.
        let yaml = """
            schema: shotlist/v3
            mode: section
            project: proj
            song:
              title: t
              audio_path: a.wav
              analysis_path: an.json
              bpm: 120.0
              duration_s: 4.0
            generated: "2026-01-01"
            generator: test
            shots:
              - id: s001
                section: verse
                time_start: 0.0
                time_end: 4.0
                duration_s: 4.0
                type: performance
                description: d
                visual_prompt: p
                mood: m
            """
        let sl = try YAMLCoding.decode(Shotlist.self, from: yaml)
        #expect(sl.shots[0].sourceMode == .generated)
    }

    // MARK: - schema_ constant / no-default

    @Test("shotlistSchemaVersion constant")
    func schemaVersionConstant() {
        #expect(shotlistSchemaVersion == "shotlist/v3")
    }

    @Test("schema_ has no default — constructing requires an explicit value")
    func schemaHasNoDefault() throws {
        // Compiles only because `schema_:` must be passed explicitly (no default
        // parameter value on Shotlist.init) — this test's mere existence with an
        // explicit argument documents/enforces that.
        let sl = try Self.shotlist(schema_: "shotlist/v3")
        #expect(sl.schema_ == "shotlist/v3")
    }

    // MARK: - schema tolerant-read

    @Test("legacy schema versions v1 and v2 decode without throwing", arguments: ["shotlist/v1", "shotlist/v2"])
    func legacySchemaVersionsAccepted(_ schemaValue: String) throws {
        let sl = try Self.shotlist(schema_: schemaValue)
        #expect(sl.schema_ == schemaValue)
    }

    @Test("unknown schema versions throw", arguments: ["shotlist/v4", "shotlist/v0"])
    func unknownSchemaVersionsThrow(_ schemaValue: String) {
        #expect(throws: Shotlist.ValidationError.self) {
            _ = try Self.shotlist(schema_: schemaValue)
        }
    }

    // MARK: - Shot id pattern

    @Test("valid shot id s001 is accepted")
    func validShotIdAccepted() throws {
        let shot = try Self.shot(id: "s001")
        #expect(shot.id == "s001")
    }

    @Test("invalid shot ids are rejected", arguments: ["s1", "shot001", "S001"])
    func invalidShotIdsRejected(_ id: String) {
        #expect(throws: Shot.ValidationError.self) {
            _ = try Self.shot(id: id)
        }
    }

    // MARK: - camera_id pattern

    @Test("nil camera_id is accepted")
    func nilCameraIdAccepted() throws {
        let shot = try Self.shot(cameraId: nil)
        #expect(shot.cameraId == nil)
    }

    @Test("valid camera_id cam01 is accepted")
    func validCameraIdAccepted() throws {
        let shot = try Self.shot(section: nil, cameraId: "cam01")
        #expect(shot.cameraId == "cam01")
    }

    @Test("invalid camera_ids are rejected", arguments: ["camera01", "cam1"])
    func invalidCameraIdsRejected(_ cameraId: String) {
        #expect(throws: Shot.ValidationError.self) {
            _ = try Self.shot(section: nil, cameraId: cameraId)
        }
    }

    // MARK: - Shot time consistency

    @Test("negative time_start throws (Field(ge=0))")
    func negativeTimeStartThrows() {
        #expect(throws: Shot.ValidationError.self) {
            _ = try Self.shot(timeStart: -1.0, timeEnd: 3.0, durationS: 4.0)
        }
    }

    @Test("time_end <= time_start throws")
    func timeEndNotAfterStartThrows() {
        #expect(throws: Shot.ValidationError.self) {
            _ = try Self.shot(timeStart: 4.0, timeEnd: 4.0, durationS: 0.0)
        }
    }

    @Test("duration_s inconsistent with time_end - time_start (beyond epsilon) throws")
    func durationInconsistentThrows() {
        #expect(throws: Shot.ValidationError.self) {
            _ = try Self.shot(timeStart: 0.0, timeEnd: 4.0, durationS: 2.0)
        }
    }

    @Test("consistent time values are accepted")
    func consistentTimesAccepted() throws {
        let shot = try Self.shot(timeStart: 1.0, timeEnd: 3.5, durationS: 2.5)
        #expect(shot.durationS == 2.5)
    }

    // MARK: - character_blocking ref validity

    @Test("a blocking entry referencing a character_ref not in character_refs throws")
    func blockingRefNotInCharacterRefsThrows() throws {
        let blocking = try CharacterBlocking(characterRef: "mira", position: "left", pose: "standing", gaze: "at camera")
        #expect(throws: Shot.ValidationError.self) {
            _ = try Self.shot(characterRefs: ["alex"], characterBlocking: [blocking])
        }
    }

    @Test("a blocking entry matching character_refs passes")
    func blockingRefMatchingPasses() throws {
        let blocking = try CharacterBlocking(characterRef: "alex", position: "left", pose: "standing", gaze: "at camera")
        let shot = try Self.shot(characterRefs: ["alex"], characterBlocking: [blocking])
        #expect(shot.characterBlocking.count == 1)
    }

    // MARK: - Shotlist shot-id-sequential validator

    @Test("shot ids with a gap throws")
    func shotIdsWithGapThrows() throws {
        let shots = try [Self.shot(id: "s001"), Self.shot(id: "s003")]
        #expect(throws: Shotlist.ValidationError.self) {
            _ = try Self.shotlist(shots: shots)
        }
    }

    @Test("shot ids out of order throws")
    func shotIdsOutOfOrderThrows() throws {
        let shots = try [Self.shot(id: "s002"), Self.shot(id: "s001")]
        #expect(throws: Shotlist.ValidationError.self) {
            _ = try Self.shotlist(shots: shots)
        }
    }

    @Test("sequential shot ids are accepted")
    func sequentialShotIdsAccepted() throws {
        let shots = try [Self.shot(id: "s001"), Self.shot(id: "s002")]
        let sl = try Self.shotlist(shots: shots)
        #expect(sl.shots.count == 2)
    }

    // MARK: - multicam mode-specific rules

    @Test("multicam shot missing camera_id throws")
    func multicamMissingCameraIdThrows() throws {
        let shots = try [Self.shot(id: "s001", section: nil, timeStart: 0.0, timeEnd: 4.0, durationS: 4.0, cameraId: nil)]
        #expect(throws: Shotlist.ValidationError.self) {
            _ = try Self.shotlist(mode: .multicam, shots: shots)
        }
    }

    @Test("multicam duplicate camera_ids across shots throws")
    func multicamDuplicateCameraIdsThrows() throws {
        let shots = try [
            Self.shot(id: "s001", section: nil, timeStart: 0.0, timeEnd: 4.0, durationS: 4.0, cameraId: "cam01"),
            Self.shot(id: "s002", section: nil, timeStart: 0.0, timeEnd: 4.0, durationS: 4.0, cameraId: "cam01"),
        ]
        #expect(throws: Shotlist.ValidationError.self) {
            _ = try Self.shotlist(mode: .multicam, shots: shots)
        }
    }

    @Test("multicam shot with non-zero time_start throws")
    func multicamNonZeroTimeStartThrows() throws {
        let shots = try [Self.shot(id: "s001", section: nil, timeStart: 1.0, timeEnd: 5.0, durationS: 4.0, cameraId: "cam01")]
        #expect(throws: Shotlist.ValidationError.self) {
            _ = try Self.shotlist(mode: .multicam, shots: shots)
        }
    }

    @Test("multicam shot with time_end far from song.duration_s throws")
    func multicamTimeEndFarFromSongDurationThrows() throws {
        let shots = try [Self.shot(id: "s001", section: nil, timeStart: 0.0, timeEnd: 2.0, durationS: 2.0, cameraId: "cam01")]
        #expect(throws: Shotlist.ValidationError.self) {
            _ = try Self.shotlist(mode: .multicam, shots: shots, song: try Self.song(durationS: 4.0))
        }
    }

    @Test("a fully valid multicam shotlist (2 cameras spanning the song) passes")
    func validMulticamShotlistPasses() throws {
        let song = try Self.song(durationS: 4.0)
        let shots = try [
            Self.shot(id: "s001", section: nil, timeStart: 0.0, timeEnd: 4.0, durationS: 4.0, cameraId: "cam01"),
            Self.shot(id: "s002", section: nil, timeStart: 0.0, timeEnd: 4.0, durationS: 4.0, cameraId: "cam02"),
        ]
        let sl = try Self.shotlist(mode: .multicam, shots: shots, song: song)
        #expect(sl.shots.count == 2)
    }

    // MARK: - non-multicam mode rules

    @Test("a beat-mode shot with a camera_id set throws")
    func beatModeShotWithCameraIdThrows() throws {
        let shots = try [Self.shot(id: "s001", section: "verse", cameraId: nil, cameraLabel: "Cam A")]
        #expect(throws: Shotlist.ValidationError.self) {
            _ = try Self.shotlist(mode: .beat, shots: shots)
        }
    }

    @Test("a beat-mode shot with nil section throws")
    func beatModeShotWithNilSectionThrows() throws {
        let shots = try [Self.shot(id: "s001", section: nil)]
        #expect(throws: Shotlist.ValidationError.self) {
            _ = try Self.shotlist(mode: .beat, shots: shots)
        }
    }

    @Test("a phrase-mode shot with nil section does NOT throw (documented exception)")
    func phraseModeShotWithNilSectionDoesNotThrow() throws {
        let shots = try [Self.shot(id: "s001", section: nil)]
        let sl = try Self.shotlist(mode: .phrase, shots: shots)
        #expect(sl.shots[0].section == nil)
    }
}
