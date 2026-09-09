import Foundation
import NexGenEngine

let fixtureFictionMinAppVersion = "1.5.7"

public struct FixtureFictionPack: Pack, PackResourceRootProviding {
    public let name = "fixture-fiction"
    public let version = "0.1.0"

    public let manifest = PackManifest(
        id: "fixture-fiction",
        displayName: "Fiction Fixture",
        tagline: "Architecture fixture for a format-neutral fiction pipeline.",
        minAppVersion: fixtureFictionMinAppVersion
    )

    public let starters = [
        PackStarter(
            id: "start",
            title: "Start the fiction fixture",
            prompt: Self.phasePrompt(
                phase: "project_init",
                handoff: "The host initialized the fiction fixture. Capture a premise or attach an existing screenplay."
            )
        ),
    ]

    public init() {}

    public func starters(for progress: PackProgress) -> [PackStarter] {
        guard progress.hasStarted, let next = progress.nextPhase else { return starters }
        return [PackStarter(
            id: "continue",
            title: "Continue — next: \(Self.phaseLabel(next))",
            prompt: Self.phasePrompt(
                phase: next,
                handoff: "Continue the fiction fixture from its durable approved state."
            )
        )]
    }

    public func register(_ registry: EngineRegistry) {
        registry.registerWiringProbe {
            PackWiring.token(pack: "fixture-fiction", nonce: $0)
        }
        registry.registerProductionProfiles([
            StandardProductionProfiles.generativeFilm,
            StandardProductionProfiles.narrativeStorytelling,
        ])
        registry.registerProductionKnowledgeConsumer(Self.knowledgeDescriptor) { _, _ in
            ProductionKnowledgeActivationMetadataV1(
                values: ["concept_type": "narrative"],
                intentTags: ["narrative", "fiction", "continuity"]
            )
        }
        registry.registerProjectDirs(["extensions", "import"])
    }

    public static func resourceRootURL() -> URL? {
        FixtureFictionPackResources.resourceRootURL()
    }

    public var packResourceRootURL: URL? { Self.resourceRootURL() }

    private static let knowledgeDescriptor = ProductionKnowledgeConsumerDescriptorV1(
        id: "fixture-fiction-production-knowledge",
        version: "1.0.0",
        packID: "fixture-fiction",
        profileResourceIDs: ["generative_film", "narrative_storytelling"],
        phaseSelections: [
            selection("project_init", "init", [
                "film-production-skill", "film-production-workflows",
            ], ["skill", "workflows"]),
            selection("screenplay", "brief", [
                "film-production-story-structures", "film-production-genre-baselines",
                "film-production-workflows",
            ], ["story-structures", "genre-baselines", "workflows"]),
            selection("scene_plan", "storyboard", [
                "film-craft-baseline", "continuity-and-coverage",
                "film-production-film-craft", "film-production-renderability",
            ], ["story-development", "coverage", "continuity", "renderability"]),
            selection("production_design", "production_design", [
                "film-craft-baseline", "production-sheet-templates",
                "film-production-production-bible", "film-production-style-control",
            ], ["cinematography", "lighting", "color", "production-bible"]),
            selection("bible", "bible", [
                "continuity-and-coverage", "production-sheet-templates",
                "film-production-production-bible", "film-production-image-model-logic",
            ], ["continuity", "character-sheet", "location-sheet", "style-sheet"]),
            selection("shotlist", "shotlist", [
                "continuity-and-coverage", "film-craft-baseline",
                "film-production-production-pipeline", "film-production-renderability",
                "film-production-video-prompting",
            ], ["camera", "coverage", "continuity", "renderability"]),
            selection("sanity", "review", [
                "continuity-and-coverage", "film-craft-baseline",
                "film-production-renderability", "film-production-post-audio-legal",
            ], ["quality-control", "continuity", "renderability"]),
            selection("frames", "frames", [
                "production-sheet-templates", "film-production-image-model-logic",
                "film-production-style-control", "film-production-renderability",
            ], ["image-model-logic", "style-control", "renderability"]),
            selection("render", "render", [
                "continuity-and-coverage", "film-production-video-prompting",
                "film-production-production-pipeline", "film-production-workflows",
            ], ["continuity", "video-prompting", "production-pipeline"]),
        ],
        budget: ProductionKnowledgeBudgetV1(
            maximumUTF8Bytes: 16_384,
            maximumEstimatedTokens: 4_096
        )
    )

    private static func selection(
        _ phase: String,
        _ knowledgePhase: String,
        _ libraries: [CreativeKnowledgeLibraryIDV1],
        _ tags: Set<String>
    ) -> ProductionKnowledgePhaseSelectionV1 {
        ProductionKnowledgePhaseSelectionV1(
            phase: phase,
            knowledgePhase: knowledgePhase,
            libraryIDs: libraries,
            intentTags: tags
        )
    }

    private static func phasePrompt(phase: String, handoff: String) -> String {
        guard let instructions = try? FixtureFictionPackResources.phaseDoc(phase),
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return handoff
        }
        return "\(handoff)\n\nFollow these packaged instructions for the current phase:\n\n\(instructions)"
    }

    private static func phaseLabel(_ phase: String) -> String {
        phase.split(separator: "_").map(\.capitalized).joined(separator: " ")
    }
}

@objc(FixtureFictionPackEntry)
public final class FixtureFictionPackEntry: PackEntry {
    public required init() { super.init() }

    public override func makePack() -> PackBox {
        PackBox(FixtureFictionPack())
    }
}
