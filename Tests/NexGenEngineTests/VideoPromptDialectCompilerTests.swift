import Foundation
import Testing
@testable import NexGenEngine

@Suite("Video PromptIR dialect compiler")
struct VideoPromptDialectCompilerTests {
    @Test("reference labels follow the exact plan order and preserve view identity")
    func exactReferenceOrder() throws {
        let references = [
            reference(plan: 0, image: 1, asset: "bea-profile", entity: "bea", view: "profile"),
            reference(plan: 1, image: 2, asset: "ari-front", entity: "ari", view: "front"),
            reference(plan: 2, image: 3, asset: "bea-front", entity: "bea", view: "front"),
        ]
        let prompt = try VideoPromptDialectCompilerV1.compile(
            ir(references: references),
            dialect: dialect(.seedance)
        )

        #expect(prompt.contains("@Image1 defines <bea / profile>"))
        #expect(prompt.contains("@Image2 defines <ari / front>"))
        #expect(prompt.contains("@Image3 defines <bea / front>"))
        #expect(prompt.range(of: "@Image1")!.lowerBound < prompt.range(of: "@Image2")!.lowerBound)
        #expect(prompt.range(of: "@Image2")!.lowerBound < prompt.range(of: "@Image3")!.lowerBound)
    }

    @Test("start and end frames retain their structural roles")
    func startEndRoles() throws {
        let references = [
            reference(plan: 0, image: 1, asset: "start", role: .startFrame),
            reference(plan: 1, image: 2, asset: "end", role: .endFrame),
        ]
        let prompt = try VideoPromptDialectCompilerV1.compile(
            ir(mode: "image-to-video", references: references),
            dialect: dialect(.cameraFirst)
        )

        #expect(prompt.contains("Reference image 1 is the exact first frame at t=0"))
        #expect(prompt.contains("Reference image 2 is the exact final frame"))
        #expect(!prompt.contains("defines <start> identity"))
    }

    @Test("omitted optional bindings cannot leak into compiled syntax")
    func optionalDropIsAbsent() throws {
        let prompt = try VideoPromptDialectCompilerV1.compile(
            ir(references: [
                reference(plan: 0, image: 1, asset: "required", entity: "ari", view: "front"),
            ]),
            dialect: dialect(.seedance)
        )

        #expect(prompt.contains("@Image1"))
        #expect(!prompt.contains("@Image2"))
        #expect(!prompt.contains("dropped-optional"))
    }

    @Test("H3 uses the official base and reference field contracts")
    func h3Contracts() throws {
        let base = try VideoPromptDialectCompilerV1.compile(
            ir(mode: "text-to-video", references: []),
            dialect: dialect(.h3)
        )
        #expect(base.hasPrefix("integrated_multimodal_description: [Shot 1]"))
        #expect(base.contains("\n\noverall_soundscape:"))
        #expect(base.contains("\n\nnon_diegetic_music: N/A"))

        let imageToVideo = try VideoPromptDialectCompilerV1.compile(
            ir(mode: "image-to-video", references: [
                self.reference(
                    plan: 0,
                    image: 1,
                    asset: "start",
                    role: .startFrame
                ),
            ]),
            dialect: dialect(.h3)
        )
        #expect(imageToVideo.hasPrefix(
            "integrated_multimodal_description: [Shot 1] ACTIVE REFERENCES: <Picture 1> is the exact first frame at t=0."
        ))
        #expect(!imageToVideo.contains("subject_definitions:"))

        let reference = try VideoPromptDialectCompilerV1.compile(
            ir(references: [
                self.reference(plan: 0, image: 1, asset: "ari", entity: "ari", view: "front"),
            ]),
            dialect: dialect(.h3)
        )
        let fields = [
            "subject_definitions:", "summary:", "retention_analysis:",
            "detailed_description:", "overall_soundscape:", "non_diegetic_music:",
        ]
        for pair in zip(fields, fields.dropFirst()) {
            #expect(reference.range(of: pair.0)!.lowerBound < reference.range(of: pair.1)!.lowerBound)
        }
    }

    @Test("invalid slot numbering is rejected")
    func rejectsInvalidOrder() {
        let invalid = reference(plan: 0, image: 2, asset: "ari", entity: "ari", view: "front")
        #expect(throws: VideoPromptCompilationErrorV1.self) {
            try VideoPromptDialectCompilerV1.compile(
                ir(references: [invalid]),
                dialect: dialect(.seedance)
            )
        }
    }

    private func ir(
        mode: String = "reference-to-video",
        references: [VideoPromptReferenceV1]
    ) -> VideoPromptIRV1 {
        VideoPromptIRV1(
            payload: PromptPayload(
                subject: "Ari turns toward Bea.",
                composition: "medium two-shot",
                camera: "static camera",
                style: "restrained live action",
                light: "soft window light",
                durationS: 5,
                aspectRatio: "16:9"
            ),
            modeID: mode,
            references: references,
            startState: "Ari faces away from Bea.",
            endState: "Ari faces Bea.",
            continuityLocks: ["Wardrobe remains unchanged"]
        )
    }

    private func dialect(_ family: VideoPromptDialectFamilyV1) -> VideoPromptDialectV1 {
        VideoPromptDialectV1(
            id: "fixture-\(family.rawValue)",
            version: 1,
            family: family,
            evidence: "fixture"
        )
    }

    private func reference(
        plan: Int,
        image: Int,
        asset: String,
        role: VideoPromptReferenceRoleV1 = .character,
        entity: String? = nil,
        view: String? = nil
    ) -> VideoPromptReferenceV1 {
        VideoPromptReferenceV1(
            planIndex: plan,
            modalityIndex: image,
            modality: .image,
            role: role,
            semanticJobID: "identity",
            assetID: asset,
            entityID: entity,
            viewID: view
        )
    }
}
