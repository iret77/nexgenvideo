import Foundation
import Testing

@testable import NexGenVideo

@Suite("InspectedObject")
struct InspectedObjectTests {

    @Test func kindLabelIsTypeNotName() {
        let ref = BibleEntityRef(kind: .character, id: "c1")
        #expect(InspectedObject.clip("x").kindLabel == "Clip")
        #expect(InspectedObject.mediaAsset("a").kindLabel == "Media")
        #expect(InspectedObject.entity(ref).kindLabel == "Character")
        #expect(InspectedObject.look.kindLabel == "Look")
        #expect(InspectedObject.shot("s1").kindLabel == "Shot")
        #expect(InspectedObject.shotUse(shot: "s1", entity: ref).kindLabel == "Use of Character")
    }

    @Test func singleClipSelectionPromotes() {
        #expect(InspectedObject.fromSelection(clipIDs: ["x"], mediaAssetIDs: [], isMarquee: false) == .clip("x"))
    }

    @Test func singleAssetSelectionPromotesWhenNoClips() {
        #expect(InspectedObject.fromSelection(clipIDs: [], mediaAssetIDs: ["m"], isMarquee: false) == .mediaAsset("m"))
    }

    @Test func multiSelectionPromotesNothing() {
        #expect(InspectedObject.fromSelection(clipIDs: ["x", "y"], mediaAssetIDs: [], isMarquee: false) == nil)
    }

    @Test func marqueePromotesNothing() {
        #expect(InspectedObject.fromSelection(clipIDs: ["x"], mediaAssetIDs: [], isMarquee: true) == nil)
    }

    @Test func emptySelectionPromotesNothing() {
        #expect(InspectedObject.fromSelection(clipIDs: [], mediaAssetIDs: [], isMarquee: false) == nil)
    }

    @Test func clipWinsOverAsset() {
        // A clip selection is the more specific object; an incidental asset highlight does not override it.
        #expect(InspectedObject.fromSelection(clipIDs: ["x"], mediaAssetIDs: ["m"], isMarquee: false) == .clip("x"))
    }
}

@Suite("BibleEntityRef")
struct BibleEntityRefTests {

    @Test func compositeIDNamespacesByKind() {
        #expect(BibleEntityRef(kind: .character, id: "1").compositeID == "character:1")
        #expect(BibleEntityRef(kind: .prop, id: "1").compositeID == "prop:1")
    }

    @Test func sameIDDifferentKindAreDistinct() {
        #expect(BibleEntityRef(kind: .character, id: "1") != BibleEntityRef(kind: .prop, id: "1"))
    }
}

@Suite("ObjectGraph breadcrumb")
struct ObjectGraphBreadcrumbTests {

    private let ref = BibleEntityRef(kind: .character, id: "c1")

    private func graph() -> ObjectGraph {
        ObjectGraph(
            entityNames: [BibleEntityRef(kind: .character, id: "c1"): "Mara"],
            shotLabels: ["s1": "Shot 3"],
            assetNames: ["a1": "Intro.mp4"],
            clipMediaRefs: ["cl1": "a1"],
            clipTrackLabels: ["cl1": "V2"]
        )
    }

    @Test func entityBreadcrumbUsesResolvedName() {
        let bc = graph().breadcrumb(for: .entity(ref))
        #expect(bc.segments.map(\.label) == ["Character", "Mara"])
        #expect(bc.flatText == "Character › Mara")
        #expect(bc.segments[1].object == .entity(ref))
        #expect(bc.segments[0].object == nil)  // the category label is not navigable
    }

    @Test func shotUseBreadcrumbDistinguishesFromEntity() {
        let bc = graph().breadcrumb(for: .shotUse(shot: "s1", entity: ref))
        #expect(bc.segments.map(\.label) == ["Shot 3", "use of Mara"])
        #expect(bc.segments[0].object == .shot("s1"))  // the shot segment navigates to the shot
        #expect(bc.segments[1].object == .shotUse(shot: "s1", entity: ref))
    }

    @Test func clipBreadcrumbShowsTrackThenName() {
        let bc = graph().breadcrumb(for: .clip("cl1"))
        #expect(bc.segments.map(\.label) == ["V2", "Intro.mp4"])
    }

    @Test func unresolvedNameFallsBackToIDNotEmpty() {
        let unknown = BibleEntityRef(kind: .prop, id: "px")
        let bc = ObjectGraph().breadcrumb(for: .entity(unknown))
        #expect(bc.segments.map(\.label) == ["Prop", "px"])
    }

    @Test func unresolvedShotFallsBackToKindLabel() {
        let bc = ObjectGraph().breadcrumb(for: .shot("s9"))
        #expect(bc.segments.map(\.label) == ["Shot"])
    }
}

@Suite("ObjectGraph builder")
struct ObjectGraphBuilderTests {

    @Test func buildsShotLabelsFromShotlistOrder() throws {
        let json = #"{"shots":[{"id":"s1"},{"id":"s2"},{"id":"s3"}]}"#.data(using: .utf8)!
        let shotlist = try JSONDecoder().decode(ShotlistData.self, from: json)
        let graph = ObjectGraph.from(bible: nil, shotlist: shotlist, timeline: Timeline(), assetNames: [:])
        #expect(graph.shotLabels == ["s1": "Shot 1", "s2": "Shot 2", "s3": "Shot 3"])
    }

    @Test func buildsClipTrackLabelsAndMediaRefs() {
        let clipV = Clip(mediaRef: "assetA", startFrame: 0, durationFrames: 30)
        let clipA = Clip(mediaRef: "assetB", startFrame: 0, durationFrames: 30)
        var timeline = Timeline()
        timeline.tracks = [
            Track(type: .video, clips: [clipV]),
            Track(type: .audio, clips: [clipA]),
        ]
        let graph = ObjectGraph.from(
            bible: nil,
            shotlist: nil,
            timeline: timeline,
            assetNames: ["assetA": "Intro.mp4", "assetB": "Song.mp3"]
        )
        #expect(graph.clipTrackLabels[clipV.id] == "V1")
        #expect(graph.clipTrackLabels[clipA.id] == "A1")
        #expect(graph.clipName(clipV.id) == "Intro.mp4")
        #expect(graph.clipName(clipA.id) == "Song.mp3")
    }

    @Test func numbersMultipleTracksOfSameKind() {
        let c1 = Clip(mediaRef: "a", startFrame: 0, durationFrames: 10)
        let c2 = Clip(mediaRef: "b", startFrame: 0, durationFrames: 10)
        var timeline = Timeline()
        timeline.tracks = [Track(type: .video, clips: [c1]), Track(type: .video, clips: [c2])]
        let graph = ObjectGraph.from(bible: nil, shotlist: nil, timeline: timeline, assetNames: [:])
        #expect(graph.clipTrackLabels[c1.id] == "V1")
        #expect(graph.clipTrackLabels[c2.id] == "V2")
    }

    @Test func emptyProjectYieldsEmptyMaps() {
        let graph = ObjectGraph.from(bible: nil, shotlist: nil, timeline: Timeline(), assetNames: [:])
        #expect(graph.entityNames.isEmpty)
        #expect(graph.shotLabels.isEmpty)
        #expect(graph.clipTrackLabels.isEmpty)
        #expect(graph.hasLook == false)
    }
}

@Suite("ObjectGraph relationship seams")
struct ObjectGraphSeamTests {

    // These edges are Phase C. They must return empty (not crash, not fabricate) until the engine read
    // model records shot↔entity and shot↔clip provenance.
    @Test func usageAndRealizationAreEmptyUntilPhaseC() {
        let graph = ObjectGraph(entityNames: [BibleEntityRef(kind: .character, id: "c1"): "Mara"])
        #expect(graph.usage(of: BibleEntityRef(kind: .character, id: "c1")).isEmpty)
        #expect(graph.clips(realizing: "s1").isEmpty)
    }
}

@Suite("ObjectGraph provenance edges")
struct ObjectGraphProvenanceTests {

    private func makeGraph() throws -> (ObjectGraph, Timeline, Clip) {
        let bibleJSON = #"{"characters":[{"id":"mara","name":"Mara"}],"ensembles":[],"props":[{"id":"jacket","name":"Jacket"}],"locations":[{"id":"rooftop","name":"Rooftop"}]}"#
        let bible = try JSONDecoder().decode(BibleData.self, from: Data(bibleJSON.utf8))
        let shotlistJSON = #"{"shots":[{"id":"s001","character_refs":["mara"],"location_ref":"rooftop","prop_refs":["jacket"]},{"id":"s002","character_refs":["mara","ghost"]}]}"#
        let shotlist = try JSONDecoder().decode(ShotlistData.self, from: Data(shotlistJSON.utf8))
        let clip = Clip(mediaRef: "assetR", startFrame: 0, durationFrames: 30)
        var timeline = Timeline()
        timeline.tracks = [Track(type: .video, clips: [clip])]
        let graph = ObjectGraph.from(
            bible: bible, shotlist: shotlist, timeline: timeline,
            assetNames: ["assetR": "s001.mp4"],
            assetPaths: ["assetR": "/proj/pipeline/renders/s001.mp4"]
        )
        return (graph, timeline, clip)
    }

    @Test func usageListsShotsInShotlistOrder() throws {
        let (graph, _, _) = try makeGraph()
        #expect(graph.usage(of: BibleEntityRef(kind: .character, id: "mara")) == ["s001", "s002"])
        #expect(graph.usage(of: BibleEntityRef(kind: .location, id: "rooftop")) == ["s001"])
        #expect(graph.usage(of: BibleEntityRef(kind: .prop, id: "jacket")) == ["s001"])
    }

    @Test func unresolvableRefsAreDropped() throws {
        let (graph, _, _) = try makeGraph()
        // "ghost" is not in the Bible → no edge is invented.
        let s2 = graph.entities(usedBy: "s002")
        #expect(s2 == [BibleEntityRef(kind: .character, id: "mara")])
    }

    @Test func clipsRealizingMatchesRenderPath() throws {
        let (graph, _, clip) = try makeGraph()
        #expect(graph.clips(realizing: "s001") == [clip.id])
        #expect(graph.clips(realizing: "s002").isEmpty)
    }

    @Test func assetNameStemAloneAlsoRealizes() {
        let clip = Clip(mediaRef: "a", startFrame: 0, durationFrames: 10)
        var timeline = Timeline()
        timeline.tracks = [Track(type: .video, clips: [clip])]
        let graph = ObjectGraph.from(
            bible: nil, shotlist: nil, timeline: timeline,
            assetNames: ["a": "s009.mp4"], assetPaths: [:]
        )
        #expect(graph.clips(realizing: "s009") == [clip.id])
    }
}
