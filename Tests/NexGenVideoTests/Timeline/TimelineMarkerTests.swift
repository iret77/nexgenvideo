import Foundation
import Testing
@testable import NexGenVideo

@Suite("Timeline markers")
struct TimelineMarkerTests {
    @Test("older timelines decode with no markers")
    func legacyTimelineMigration() throws {
        let data = Data(#"{"fps":24,"width":1280,"height":720,"settingsConfigured":true,"tracks":[]}"#.utf8)
        let timeline = try JSONDecoder().decode(Timeline.self, from: data)

        #expect(timeline.markers.isEmpty)
        #expect(timeline.fps == 24)
    }

    @Test("marker identity and optional metadata survive a timeline round trip")
    func persistentRoundTrip() throws {
        let marker = TimelineMarker(
            id: "stable-marker-id",
            startFrame: 42,
            durationFrames: 18,
            title: "Review entrance",
            note: "Hold two frames longer.",
            type: .review,
            color: TextStyle.RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1)
        )
        let original = Timeline(fps: 24, markers: [marker])
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(original))

        #expect(decoded == original)
        #expect(decoded.markers.first?.id == "stable-marker-id")
    }

    @Test("upstream marker names and comments migrate without losing identity")
    func legacyMarkerFieldMigration() throws {
        let data = Data(#"{"id":"marker-1","startFrame":9,"durationFrames":0,"name":"Old title","comment":"Old note"}"#.utf8)
        let marker = try JSONDecoder().decode(TimelineMarker.self, from: data)

        #expect(marker.id == "marker-1")
        #expect(marker.title == "Old title")
        #expect(marker.note == "Old note")
    }
}

@MainActor
@Suite("Timeline marker mutations")
struct TimelineMarkerMutationTests {
    @Test("one marker edit is one undo operation")
    func atomicUndo() throws {
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undoManager = undo

        let marker = try editor.createTimelineMarker(startFrame: 12, title: "Beat")
        #expect(editor.timeline.markers == [marker])
        #expect(undo.undoActionName == "Add Marker")

        undo.undo()
        #expect(editor.timeline.markers.isEmpty)
        undo.redo()
        #expect(editor.timeline.markers == [marker])
    }

    @Test("failed validation changes neither timeline nor undo stack")
    func validationIsAtomic() throws {
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undoManager = undo
        let marker = try editor.createTimelineMarker(startFrame: 12, title: "Valid")
        undo.removeAllActions()
        let before = editor.timeline

        #expect(throws: TimelineMarkerMutationError.self) {
            _ = try editor.updateTimelineMarker(id: marker.id) {
                $0.startFrame = -1
                $0.title = ""
            }
        }
        #expect(editor.timeline == before)
        #expect(undo.canUndo == false)
    }

    @Test("marker, clip, gap, and range selections remain exclusive")
    func selectionIsExclusive() {
        let editor = EditorViewModel()
        editor.timeline.markers = [TimelineMarker(id: "marker", startFrame: 12, title: "Beat")]

        editor.selectedClipIds = ["clip"]
        editor.selectedTimelineMarkerIds = ["marker"]
        #expect(editor.selectedClipIds.isEmpty)

        editor.selectedTimelineRange = TimelineRangeSelection(startFrame: 0, endFrame: 12)
        #expect(editor.selectedTimelineMarkerIds.isEmpty)

        editor.selectedTimelineMarkerIds = ["marker"]
        editor.selectedGap = GapSelection(trackIndex: 0, range: FrameRange(start: 12, end: 24))
        #expect(editor.selectedTimelineMarkerIds.isEmpty)
    }

    @Test("undo removes selection for a marker that no longer exists")
    func undoClearsStaleSelection() throws {
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undoManager = undo
        let marker = try editor.createTimelineMarker(startFrame: 12, title: "Beat")
        #expect(editor.selectedTimelineMarkerIds == [marker.id])

        undo.undo()

        #expect(editor.timeline.markers.isEmpty)
        #expect(editor.selectedTimelineMarkerIds.isEmpty)
    }

    @Test("frame-rate changes rescale point and range markers by their endpoints")
    func frameRateRescale() {
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undoManager = undo
        editor.timeline = Timeline(fps: 24, markers: [
            TimelineMarker(id: "point", startFrame: 12, title: "Point"),
            TimelineMarker(id: "range", startFrame: 6, durationFrames: 12, title: "Range"),
        ])

        editor.applyTimelineSettings(fps: 48, width: 1920, height: 1080)

        #expect(editor.timeline.markers[0].startFrame == 24)
        #expect(editor.timeline.markers[0].durationFrames == 0)
        #expect(editor.timeline.markers[1].startFrame == 12)
        #expect(editor.timeline.markers[1].durationFrames == 24)

        undo.undo()
        #expect(editor.timeline.markers[0].startFrame == 12)
        #expect(editor.timeline.markers[1].startFrame == 6)
        #expect(editor.timeline.markers[1].durationFrames == 12)
    }
}
