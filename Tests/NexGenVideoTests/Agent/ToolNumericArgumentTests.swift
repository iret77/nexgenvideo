import Foundation
import Testing

@testable import NexGenVideo

@Suite("Agent and MCP numeric argument safety")
struct ToolNumericArgumentTests {
    @Test("shared integer parser accepts lossless Int, Double, and JSON numbers")
    func sharedParserAcceptsLosslessNumbers() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(#"{"value":7,"large":9007199254740993}"#.utf8)
        )
        let json = try #require(object as? [String: Any])
        let jsonNumber = try #require(json["value"])
        let largeJSONNumber = try #require(json["large"])

        #expect(ToolIntegerArgument.exact(7 as Int) == 7)
        #expect(ToolIntegerArgument.exact(7.0 as Double) == 7)
        #expect(ToolIntegerArgument.exact(jsonNumber) == 7)
        #expect(ToolIntegerArgument.exact(Int.max) == Int.max)
        #expect(ToolIntegerArgument.exact(largeJSONNumber) == 9_007_199_254_740_993)
        #expect(
            ToolIntegerArgument.exact(
                Double(ToolIntegerArgument.maximumFrame),
                in: ToolIntegerArgument.frameBounds
            ) == ToolIntegerArgument.maximumFrame
        )
    }

    @Test("shared integer parser rejects non-lossless and unbounded numbers")
    func sharedParserRejectsUnsafeNumbers() {
        for value in [Double.nan, .infinity, -.infinity, 7.5, 1e300] {
            #expect(ToolIntegerArgument.exact(value) == nil)
        }
        #expect(ToolIntegerArgument.exact(true) == nil)
        #expect(ToolIntegerArgument.exact(-1, in: ToolIntegerArgument.frameBounds) == nil)
        #expect(
            ToolIntegerArgument.exact(
                ToolIntegerArgument.maximumFrame + 1,
                in: ToolIntegerArgument.frameBounds
            ) == nil
        )
    }

    @Test("integer schema failures identify the tool and field before mutation")
    @MainActor
    func schemaFailuresAreAgentFacingAndNonMutating() async {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "C1", start: 0, duration: 100)]),
        ]))
        let before = harness.editor.timeline
        let cases: [(String, [String: Any], String)] = [
            ("get_timeline", ["startFrame": Double.nan], "get_timeline.startFrame"),
            ("get_timeline", ["startFrame": Double.infinity], "get_timeline.startFrame"),
            ("get_timeline", ["startFrame": 1.5], "get_timeline.startFrame"),
            ("get_timeline", ["startFrame": -1], "get_timeline.startFrame"),
            ("get_timeline", ["startFrame": 1e300], "get_timeline.startFrame"),
            ("get_timeline", ["startFrame": true], "get_timeline.startFrame"),
            ("get_timeline", ["startFrame": "12"], "get_timeline.startFrame"),
            (
                "add_clips",
                ["entries": [["mediaRef": "missing", "startFrame": 1e300, "durationFrames": 1]]],
                "add_clips.entries[0].startFrame"
            ),
            ("remove_tracks", ["trackIndexes": [1e300]], "remove_tracks.trackIndexes[0]"),
            ("remove_words", ["words": [1e300]], "remove_words.words[0]"),
        ]

        for (tool, arguments, path) in cases {
            let result = await harness.runRaw(tool, args: arguments)
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains(path))
            #expect(harness.editor.timeline == before)
        }
    }

    @Test("valid integer boundaries remain accepted")
    @MainActor
    func validBoundariesRemainAccepted() async {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "C1", start: 0, duration: 100)]),
        ]))
        let result = await harness.runRaw("get_timeline", args: [
            "startFrame": 0,
            "endFrame": ToolIntegerArgument.maximumFrame,
        ])

        #expect(!result.isError)
    }

    @Test("keyframe and range conversions reject extremes before mutation")
    @MainActor
    func positionalNumbersAreRejectedBeforeMutation() async {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "C1", start: 0, duration: 100)]),
        ]))
        let before = harness.editor.timeline

        for frame in [-1.0, 1.5, 1e300, Double.infinity] {
            let result = await harness.runRaw("set_keyframes", args: [
                "clipId": "C1",
                "property": "opacity",
                "keyframes": [[frame, 0.5]],
            ])
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains("set_keyframes.keyframes[0][0]"))
            #expect(harness.editor.timeline == before)
        }

        for speed in [Double.leastNonzeroMagnitude, 1e300] {
            let result = await harness.runRaw("set_clip_properties", args: [
                "clipIds": ["C1"],
                "speed": speed,
            ])
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains("set_clip_properties.speed"))
            #expect(harness.editor.timeline == before)
        }

        let range = await harness.runRaw("ripple_delete_ranges", args: [
            "trackIndex": 0,
            "units": "frames",
            "ranges": [[0.0, 1e300]],
        ])
        #expect(range.isError)
        #expect(ToolHarness.textOf(range).contains("ripple_delete_ranges.ranges"))
        #expect(harness.editor.timeline == before)
    }

    @Test("word spans reject invalid indices and bound valid extreme spans")
    @MainActor
    func wordSpanBoundsPreventExtremeLoops() throws {
        let invalidValues: [Any] = [-1, 1.5, 1e300, Double.nan, Double.infinity]
        for value in invalidValues {
            #expect(throws: ToolError.self) {
                try ToolExecutor.parseWordSpans([value])
            }
        }

        let spans = try ToolExecutor.parseWordSpans([[0, ToolIntegerArgument.maximumFrame]])
        let selection = ToolExecutor.boundedWordSelection(spans, maxIndex: 3)
        #expect(selection.selected == Set([0, 1, 2, 3]))
        #expect(selection.ignored == [ToolIntegerArgument.maximumFrame])
    }

    @Test("nested batch integer failures stop before batch preparation")
    @MainActor
    func batchRejectsUnsafeNestedInteger() async {
        let harness = ToolHarness()
        let result = await harness.runRaw("prepare_generation_batch", args: [
            "requestID": UUID().uuidString,
            "items": [[
                "tool": "generate_video",
                "purpose": "Test numeric validation",
                "request": [
                    "prompt": "compiled prompt",
                    "shotId": "none",
                    "duration": 1e300,
                ],
            ]],
        ])

        #expect(result.isError)
        #expect(
            ToolHarness.textOf(result)
                .contains("prepare_generation_batch.items[0].request.duration")
        )
        #expect(harness.editor.generationBatchCoordinator.pending == nil)
    }

    @Test("audio sync rejects a search window that cannot form a safe loop bound")
    @MainActor
    func audioSyncRejectsUnsafeSearchWindow() async {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "reference", start: 0, duration: 100)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "target", start: 0, duration: 100)]),
        ]))
        let before = harness.editor.timeline
        let result = await harness.runRaw("sync_audio", args: [
            "referenceClipId": "reference",
            "targetClipId": "target",
            "searchWindowSeconds": 1e300,
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("sync_audio.searchWindowSeconds"))
        #expect(harness.editor.timeline == before)
    }
}
