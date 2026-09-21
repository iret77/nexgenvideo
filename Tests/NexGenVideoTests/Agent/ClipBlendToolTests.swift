import Foundation
import Testing
@testable import NexGenVideo

@Suite("Agent — clip blend modes")
@MainActor
struct ClipBlendToolTests {
    @Test func toolAndInspectorShareMutationAndUndo() async throws {
        let clips = [ClipType.video, .image, .text, .lottie].enumerated().map { index, type in
            Fixtures.clip(id: "c\(index)", mediaType: type, start: index * 30, duration: 30)
        }
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: clips)])
        let native = ToolHarness(timeline: timeline)
        let agent = ToolHarness(timeline: timeline)
        let undo = UndoManager()
        undo.groupsByEvent = false
        agent.editor.undoManager = undo
        try native.editor.setClipBlendMode(.multiply, clipIds: clips.map(\.id))
        let result = await agent.runRaw("set_clip_properties", args: ["clipIds": clips.map(\.id), "blendMode": "multiply"])
        #expect(!result.isError)
        #expect(native.editor.timeline == agent.editor.timeline)
        undo.undo()
        #expect(agent.editor.timeline == timeline)
        undo.redo()
        #expect(native.editor.timeline == agent.editor.timeline)
        let read = try await agent.runOK("get_timeline") as? [String: Any]
        let tracks = read?["tracks"] as? [[String: Any]]
        let rows = tracks?.first?["clips"] as? [[String: Any]]
        #expect(rows?.count == 4)
        #expect(rows?.allSatisfy { $0["blendMode"] as? String == "multiply" } == true)
    }

    @Test func invalidModeAndAudioTargetRejectEntireMutation() async {
        let video = Fixtures.clip(id: "v", start: 0, duration: 30)
        let audio = Fixtures.clip(id: "a", mediaType: .audio, start: 0, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [video]), Track(type: .audio, clips: [audio])]))
        let before = h.editor.timeline
        let requests: [[String: Any]] = [
            ["clipIds": ["v"], "blendMode": "future", "opacity": 0.25],
            ["clipIds": ["v", "a"], "blendMode": "screen", "opacity": 0.25],
            ["clipIds": ["v", "missing"], "blendMode": "screen"],
        ]
        for args in requests {
            #expect(await h.runRaw("set_clip_properties", args: args).isError)
            #expect(h.editor.timeline == before)
        }
    }

    @Test func blendDoesNotPropagateToLinkedAudioOrClearOpacityAnimation() async {
        var video = Fixtures.clip(id: "v", start: 0, duration: 30)
        var audio = Fixtures.clip(id: "a", mediaType: .audio, start: 0, duration: 30)
        video.linkGroupId = "linked"
        audio.linkGroupId = "linked"
        video.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: 0.2), Keyframe(frame: 30, value: 0.8)])
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [video]), Track(type: .audio, clips: [audio])]))
        #expect(!(await h.runRaw("set_clip_properties", args: ["clipIds": ["v"], "blendMode": "screen"])).isError)
        #expect(h.editor.clipFor(id: "v")?.opacityTrack == video.opacityTrack)
        #expect(h.editor.clipFor(id: "a") == audio)
    }

    @Test func schemaDeclaresClosedVersionOneSet() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .setClipProperties })
        let properties = try #require(tool.inputSchema["properties"] as? [String: [String: Any]])
        let modes = try #require(properties["blendMode"]?["enum"] as? [String])
        #expect(modes == ClipBlendMode.allCases.map(\.rawValue))
        #expect(tool.inputSchema["additionalProperties"] as? Bool == false)
        #expect((tool.inputSchema["required"] as? [String])?.contains("clipIds") == true)
    }
}
