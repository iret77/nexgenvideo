import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("marker agent tools")
struct MarkerToolTests {
    private func harness() -> (ToolHarness, UndoManager) {
        let harness = ToolHarness(timeline: Timeline(fps: 24))
        let undo = UndoManager()
        harness.editor.undoManager = undo
        return (harness, undo)
    }

    @Test("create, read, update, and delete use one stable marker id")
    func lifecycle() async throws {
        let (harness, undo) = harness()
        _ = undo
        let created = try #require(try await harness.runOK("manage_markers", args: [
            "action": "create",
            "startFrame": 48,
            "durationFrames": 12,
            "title": "Check eyeline",
            "note": "Review with director.",
            "type": "review",
            "color": "#336699",
        ]) as? [String: Any])
        let markerID = try #require(created["markerId"] as? String)

        let timeline = try #require(try await harness.runOK("get_timeline") as? [String: Any])
        let markers = try #require(timeline["markers"] as? [[String: Any]])
        #expect(markers.count == 1)
        #expect(markers[0]["markerId"] as? String == markerID)
        #expect(markers[0]["endFrame"] as? Int == 60)
        #expect(markers[0]["type"] as? String == "review")

        let updated = try #require(try await harness.runOK("manage_markers", args: [
            "action": "update",
            "markerId": markerID,
            "startFrame": 72,
            "title": "Eyeline approved",
            "type": "none",
            "color": "automatic",
        ]) as? [String: Any])
        #expect(updated["markerId"] as? String == markerID)
        #expect(updated["startFrame"] as? Int == 72)
        #expect(updated["type"] == nil)
        #expect(updated["color"] == nil)

        let deleted = await harness.runRaw("manage_markers", args: [
            "action": "delete",
            "markerId": markerID,
        ])
        #expect(deleted.isError == false)
        #expect(harness.editor.timeline.markers.isEmpty)
    }

    @Test("one agent marker mutation is one undo action")
    func atomicUndo() async {
        let (harness, undo) = harness()
        _ = undo
        let create = await harness.runRaw("manage_markers", args: [
            "action": "create",
            "startFrame": 10,
            "title": "Undo me",
        ])
        #expect(create.isError == false)
        #expect(harness.editor.timeline.markers.count == 1)

        let result = await harness.runRaw("undo")
        #expect(result.isError == false)
        #expect(harness.editor.timeline.markers.isEmpty)
    }

    @Test("schema rejects wrong action fields and enum values before mutation")
    func schemaValidation() async {
        let (harness, undo) = harness()
        _ = undo
        let extra = await harness.runRaw("manage_markers", args: [
            "action": "delete",
            "markerId": "missing",
            "title": "Not allowed",
        ])
        let invalidType = await harness.runRaw("manage_markers", args: [
            "action": "create",
            "startFrame": 0,
            "title": "Invalid",
            "type": "pipeline_approval",
        ])

        #expect(extra.isError)
        #expect(invalidType.isError)
        #expect(harness.editor.timeline.markers.isEmpty)
        #expect(undo.canUndo == false)
    }

    @Test("windowed timeline reads use marker range intersection")
    func windowedRead() async throws {
        let timeline = Timeline(fps: 24, markers: [
            TimelineMarker(id: UUID().uuidString, startFrame: 5, title: "Before"),
            TimelineMarker(id: UUID().uuidString, startFrame: 15, durationFrames: 10, title: "Overlap"),
            TimelineMarker(id: UUID().uuidString, startFrame: 30, title: "After"),
        ])
        let harness = ToolHarness(timeline: timeline)
        let result = try #require(try await harness.runOK("get_timeline", args: [
            "startFrame": 20,
            "endFrame": 30,
        ]) as? [String: Any])
        let markers = try #require(result["markers"] as? [[String: Any]])

        #expect(markers.map { $0["title"] as? String } == ["Overlap"])
    }
}
