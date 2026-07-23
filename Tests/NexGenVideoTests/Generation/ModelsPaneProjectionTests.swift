import Testing
@testable import NexGenVideo

@Suite("Models settings availability projection")
struct ModelsPaneProjectionTests {
    private let image: [ModelsPaneProjection.Row] = [
        .init(id: "image-ready", displayName: "Ready Image"),
        .init(id: "image-locked", displayName: "Locked Image"),
    ]
    private let video: [ModelsPaneProjection.Row] = [
        .init(id: "video-ready", displayName: "Ready Video"),
    ]

    @Test("Only runnable models enter settings sections")
    func filtersUnavailableModels() {
        let sections = ModelsPaneProjection.sections(
            image: image,
            video: video,
            audio: [],
            query: "",
            canRun: { $0.hasSuffix("ready") }
        )

        #expect(sections.flatMap(\.rows).map(\.id) == ["image-ready", "video-ready"])
        #expect(sections.contains { $0.id == "audio" } == false)
    }

    @Test("Search operates on the same runnable subset")
    func searchDoesNotReintroduceUnavailableModels() {
        let sections = ModelsPaneProjection.sections(
            image: image,
            video: video,
            audio: [],
            query: "locked",
            canRun: { $0 == "image-ready" }
        )

        #expect(sections.isEmpty)
    }
}
