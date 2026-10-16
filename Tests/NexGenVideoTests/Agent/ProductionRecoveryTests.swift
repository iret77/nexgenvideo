import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Production review and recovery")
struct ProductionRecoveryTests {
    @Test("Changing guessed values cannot evade the repair limit")
    func repairLimit() {
        var attempts = PipelineRepairAttempts()
        let firstFailure = attempts.record(scope: "project/session/shotlist", failure: "location")
        #expect(!firstFailure)
        let secondFailure = attempts.record(scope: "project/session/shotlist", failure: "environment")
        #expect(!secondFailure)
        let thirdFailure = attempts.record(scope: "project/session/shotlist", failure: "background")
        #expect(thirdFailure)
        let otherScope = attempts.record(scope: "other/session/shotlist", failure: "location")
        #expect(!otherScope)
        let successfulWrite = attempts.record(scope: "project/session/shotlist", failure: nil)
        #expect(!successfulWrite)
        let failureAfterSuccess = attempts.record(scope: "project/session/shotlist", failure: "location")
        #expect(!failureAfterSuccess)
    }

    @Test("Silence is measured from real events, not timer ticks")
    func activityTiming() {
        let start = Date(timeIntervalSince1970: 100)
        let waiting = AgentActivityTiming(startedAt: start, lastEventAt: nil)
        #expect(!waiting.isUnconfirmed(at: start.addingTimeInterval(59)))
        #expect(waiting.isUnconfirmed(at: start.addingTimeInterval(60)))
        let resumed = AgentActivityTiming(startedAt: start, lastEventAt: start.addingTimeInterval(90))
        #expect(resumed.elapsed(at: start.addingTimeInterval(100)) == 100)
        #expect(resumed.silence(at: start.addingTimeInterval(100)) == 10)
        #expect(!resumed.isUnconfirmed(at: start.addingTimeInterval(100)))
    }

    @Test("Reference identifiers expose the same syntax enforced by the writer")
    func identifierContract() throws {
        let pattern = try #require(PipelineExecutionIdentifierContract.schema("role")["pattern"] as? String)
        #expect("location".range(of: pattern, options: .regularExpression) == nil)
        #expect("environment".range(of: pattern, options: .regularExpression) == nil)
        #expect(CoreReferenceSemanticJobIDV1.referenceAnchor.range(of: pattern, options: .regularExpression) != nil)
        #expect("musicvideo.performance-anchor".range(of: pattern, options: .regularExpression) != nil)
        let contract = PipelineExecutionIdentifierContract.discovery
        let anchor = try #require(contract["reference_anchor"] as? [String: String])
        #expect(anchor["semantic_job_id"] == CoreReferenceSemanticJobIDV1.referenceAnchor)
        #expect(anchor["input_slot_id"] == CoreReferenceInputSlotIDV1.referenceImage)
    }

    @Test("Writer rejects entity kinds as semantic roles and accepts namespaced anchors")
    func referenceDemandValidation() throws {
        func demand(_ role: String) -> PipelineReferenceDemandInput {
            PipelineReferenceDemandInput(id: "street", assetPath: "assets/street.png", modality: .image,
                semanticJobID: role, isRequired: true, priority: 0, preservationScopeIDs: [],
                exclusionDemandIDs: [], inputSlotID: CoreReferenceInputSlotIDV1.referenceImage,
                modeID: "reference", identityLock: false, entityID: "main_street", canonIDs: [],
                stateID: nil, viewID: nil)
        }
        #expect(throws: PipelineExecutionShotInputValidationError.invalidIdentifier(
            field: "reference.semantic_job_id", value: "location")) {
            try demand("location").validate(path: "reference")
        }
        try demand(CoreReferenceSemanticJobIDV1.referenceAnchor).validate(path: "reference")
        do {
            try demand(CoreReferenceSemanticJobIDV1.firstFrame).validate(path: "reference")
            Issue.record("A dedicated core job was accepted as a reference demand")
        } catch {
            #expect(error.localizedDescription.contains("reference.semantic_job_id"))
            #expect(error.localizedDescription.contains("core_inputs"))
        }
    }

    @Test("Shot List writer accepts only host reference roles with their modalities")
    func referenceRoleVocabulary() throws {
        let route = videoRoute("styled", inputKinds: ["video"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceVideo, .video, order: 3),
        ])
        var style = demandObject(role: CoreReferenceSemanticJobIDV1.styleReference, modality: "video")
        style["input_slot_id"] = CoreReferenceInputSlotIDV1.referenceVideo
        let styled = try generatedInput(demands: [style])
        try PipelineReferenceRouteContract.validate([styled], routes: [route])
        for (role, modality, field) in [
            ("core.location", "image", "semantic_job_id"),
            ("look.identity", "image", "semantic_job_id"),
            (CoreReferenceSemanticJobIDV1.referenceAnchor, "audio", "modality"),
            (CoreReferenceSemanticJobIDV1.voiceReference, "image", "modality"),
        ] {
            let input = try generatedInput(demands: [
                demandObject(role: role, modality: modality),
            ])
            do {
                try PipelineReferenceRouteContract.validate([input], routes: [route])
                Issue.record("\(role) with \(modality) was accepted")
            } catch {
                #expect(error.localizedDescription.contains("reference_demands[0].\(field)"))
            }
        }
        let schema = PipelineExecutionIdentifierContract.roleSchema
        #expect(schema["enum"] as? [String]
            == ProductionReferenceDemandSemanticsV1.selectableModalities.keys.sorted())
    }

    @Test("Generated reference demands must match a slot an activated video route offers")
    func referenceDemandsMatchActivatedRoutes() throws {
        let anchor = demandObject(role: CoreReferenceSemanticJobIDV1.referenceAnchor, modality: "image")
        let input = try generatedInput(demands: [anchor])
        let route = videoRoute("anchored", inputKinds: ["image"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceImage, .image, order: 2),
        ])
        try PipelineReferenceRouteContract.validate([input], routes: [route])

        do {
            try PipelineReferenceRouteContract.validate([input], routes: [])
            Issue.record("A reference demand without an activated route was accepted")
        } catch {
            #expect(error.localizedDescription.contains("reference_demands[0].input_slot_id"))
            #expect(error.localizedDescription.contains("activate a provider"))
        }

        var otherMode = anchor
        otherMode["mode_id"] = "image-to-video"
        let unoffered = try generatedInput(demands: [otherMode], modes: [Self.mode, "image-to-video"])
        do {
            try PipelineReferenceRouteContract.validate([unoffered], routes: [route])
            Issue.record("A mode the slot does not offer was accepted")
        } catch {
            #expect(error.localizedDescription.contains("execution_shot[s001]"))
        }

        var retired = anchor
        retired["input_slot_id"] = "reference.image.anchor"
        let legacy = try generatedInput(demands: [retired])
        do {
            try PipelineReferenceRouteContract.validate([legacy], routes: [route])
            Issue.record("The retired anchor slot was accepted for a new write")
        } catch {
            #expect(error.localizedDescription.contains("reference_demands[0].input_slot_id"))
            #expect(error.localizedDescription.contains("retired"))
            #expect(error.localizedDescription.contains(CoreReferenceInputSlotIDV1.referenceImage))
        }
    }

    @Test("A shot's demands must bind together on one activated route")
    func referenceDemandsBindPerShot() throws {
        let imageOnly = videoRoute("image-only", inputKinds: ["image"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceImage, .image, order: 2),
        ])
        let videoOnly = videoRoute("video-only", inputKinds: ["video"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceVideo, .video, order: 3),
        ])
        var motion = demandObject(role: CoreReferenceSemanticJobIDV1.motionReference, modality: "video")
        motion["id"] = "walk"
        motion["asset_path"] = "bible/walk.mp4"
        motion["input_slot_id"] = CoreReferenceInputSlotIDV1.referenceVideo
        let input = try generatedInput(demands: [
            demandObject(role: CoreReferenceSemanticJobIDV1.referenceAnchor, modality: "image"),
            motion,
        ])

        do {
            try PipelineReferenceRouteContract.validate([input], routes: [imageOnly, videoOnly])
            Issue.record("Demands split across two routes were accepted")
        } catch {
            #expect(error.localizedDescription.contains("execution_shot[s001]:"))
            #expect(error.localizedDescription.contains("no single activated video route"))
            #expect(error.localizedDescription.contains(
                ProductionRouteDeficitCodeV1.inputSlotUnsupported.rawValue
            ))
        }
        let both = videoRoute("both", inputKinds: ["image", "video"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceImage, .image, order: 2),
            slot(CoreReferenceInputSlotIDV1.referenceVideo, .video, order: 3),
        ])
        try PipelineReferenceRouteContract.validate([input], routes: [imageOnly, videoOnly, both])
    }

    @Test("Optional demands never decide the route but must be offered by an activated route")
    func optionalDemandsFollowRender() throws {
        let imageOnly = videoRoute("image-only", inputKinds: ["image"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceImage, .image, order: 2),
        ])
        let videoOnly = videoRoute("video-only", inputKinds: ["video"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceVideo, .video, order: 3),
        ])
        let anchor = demandObject(role: CoreReferenceSemanticJobIDV1.referenceAnchor, modality: "image")
        var motion = demandObject(role: CoreReferenceSemanticJobIDV1.motionReference, modality: "video")
        motion["id"] = "walk"
        motion["asset_path"] = "bible/walk.mp4"
        motion["input_slot_id"] = CoreReferenceInputSlotIDV1.referenceVideo
        motion["is_required"] = false
        let input = try generatedInput(demands: [anchor, motion])
        try PipelineReferenceRouteContract.validate([input], routes: [imageOnly, videoOnly])

        var invented = motion
        invented["semantic_job_id"] = "core.location"
        let inventedRole = try generatedInput(demands: [anchor, invented])
        do {
            try PipelineReferenceRouteContract.validate([inventedRole], routes: [imageOnly, videoOnly])
            Issue.record("An optional demand with an invented role was accepted")
        } catch {
            #expect(error.localizedDescription.contains("reference_demands[1].semantic_job_id"))
        }

        var voice = demandObject(role: CoreReferenceSemanticJobIDV1.voiceReference, modality: "audio")
        voice["id"] = "hum"
        voice["asset_path"] = "bible/hum.wav"
        voice["input_slot_id"] = CoreReferenceInputSlotIDV1.referenceAudio
        voice["is_required"] = false
        let unoffered = try generatedInput(demands: [anchor, voice])
        do {
            try PipelineReferenceRouteContract.validate([unoffered], routes: [imageOnly, videoOnly])
            Issue.record("An optional demand no activated route offers was accepted")
        } catch {
            #expect(error.localizedDescription.contains("execution_shot[s001].reference_demands[1].input_slot_id"))
            #expect(error.localizedDescription.contains("no activated video route offers"))
        }
    }

    @Test("Required references beyond a route's reference limit fail at write as at Render")
    func requiredReferencesRespectRouteCapacity() throws {
        let oneImage = videoRoute("one-image", inputKinds: ["image"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceImage, .image, order: 2),
        ], imageCapacity: 1)
        let street = demandObject(role: CoreReferenceSemanticJobIDV1.referenceAnchor, modality: "image")
        var cheese = street
        cheese["id"] = "cheese"
        cheese["asset_path"] = "bible/cheese.png"
        cheese["entity_id"] = "cheese"
        let overCapacity = try generatedInput(demands: [street, cheese])
        do {
            try PipelineReferenceRouteContract.validate([overCapacity], routes: [oneImage])
            Issue.record("Two required images on a one-image route were accepted")
        } catch {
            #expect(error.localizedDescription.contains("execution_shot[s001]:"))
            #expect(error.localizedDescription.contains(
                ProductionRouteDeficitCodeV1.referenceCapacity.rawValue
            ))
            #expect(error.localizedDescription.contains(CapabilityFieldIDV1.referenceImages))
        }
        cheese["is_required"] = false
        let optionalSecond = try generatedInput(demands: [street, cheese])
        try PipelineReferenceRouteContract.validate([optionalSecond], routes: [oneImage])
    }

    @Test("Shot modes and core inputs are checked against the same route")
    func requirementModesAndCoreInputsRoute() throws {
        let anchor = demandObject(role: CoreReferenceSemanticJobIDV1.referenceAnchor, modality: "image")
        let route = videoRoute("anchored", inputKinds: ["image"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceImage, .image, order: 2),
        ])
        let unsupportedMode = try generatedInput(demands: [anchor], modes: [Self.mode, "fixture-unsupported"])
        do {
            try PipelineReferenceRouteContract.validate([unsupportedMode], routes: [route])
            Issue.record("A generation mode no route supports was accepted")
        } catch {
            #expect(error.localizedDescription.contains("execution_shot[s001].generation_requirement.mode_ids"))
        }

        var undeclared = anchor
        undeclared["mode_id"] = "fixture-undeclared"
        let foreignMode = try generatedInput(demands: [undeclared])
        do {
            try PipelineReferenceRouteContract.validate([foreignMode], routes: [route])
            Issue.record("A demand mode no route offers was accepted")
        } catch {
            #expect(error.localizedDescription.contains("reference_demands[0].input_slot_id"))
            #expect(error.localizedDescription.contains("fixture-undeclared"))
        }

        let keyframed = try generatedInput(demands: [anchor], coreInputs: ["first_frame_mode_id": Self.mode])
        do {
            try PipelineReferenceRouteContract.validate([keyframed], routes: [route])
            Issue.record("A first frame the route cannot take was accepted")
        } catch {
            #expect(error.localizedDescription.contains("execution_shot[s001].core_inputs.first_frame_mode_id"))
            #expect(error.localizedDescription.contains(CoreReferenceInputSlotIDV1.firstFrame))
        }
        let framed = videoRoute("framed", inputKinds: ["image"], slots: [
            slot(CoreReferenceInputSlotIDV1.firstFrame, .image, order: 0),
            slot(CoreReferenceInputSlotIDV1.referenceImage, .image, order: 2),
        ])
        try PipelineReferenceRouteContract.validate([keyframed], routes: [framed])
    }

    @Test("Unfinished catalog discovery is retryable and never asks for a provider")
    func pendingDiscoveryIsRetryable() throws {
        let input = try generatedInput(demands: [
            demandObject(role: CoreReferenceSemanticJobIDV1.referenceAnchor, modality: "image"),
        ])
        do {
            try PipelineReferenceRouteContract.validate([input], routes: [], discoveryComplete: false)
            Issue.record("An unknown route set was treated as a verdict")
        } catch let error as ToolError {
            #expect(error.kind == .hostBusy)
            #expect(error.message.contains("write_shotlist"))
            #expect(!error.message.contains("activate a provider"))
        }
        let route = videoRoute("anchored", inputKinds: ["image"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceImage, .image, order: 2),
        ])
        try PipelineReferenceRouteContract.validate([input], routes: [route], discoveryComplete: false)
        try PipelineReferenceRouteContract.validate([input], check: .storedDemands)
    }

    @Test("Render resolves the retired anchor slot to the offered reference-image slot")
    func retiredAnchorSlotResolvesForRender() throws {
        #expect(ProductionInputSlotAliasV1.isRetired("reference.image.anchor"))
        #expect(!ProductionInputSlotAliasV1.isRetired(CoreReferenceInputSlotIDV1.referenceImage))
        #expect(ProductionInputSlotAliasV1.routedSlotID("reference.image.anchor")
            == CoreReferenceInputSlotIDV1.referenceImage)
        let route = videoRoute("anchored", inputKinds: ["image"], slots: [
            slot(CoreReferenceInputSlotIDV1.referenceImage, .image, order: 2),
        ])
        let requirement = ProductionRequirementV1(
            modalityID: "video",
            modeIDs: [Self.mode],
            visibleEntityCount: 0
        )
        func demand(_ slotID: String) -> ReferenceDemandV1 {
            ReferenceDemandV1(
                id: "street", assetID: "asset-street", modality: .image,
                semanticJobID: CoreReferenceSemanticJobIDV1.referenceAnchor,
                isRequired: true, priority: 0,
                inputSlotID: slotID, modeID: Self.mode
            )
        }
        let legacy = ProductionRequirementResolverV1.slotAndModeEvaluations(
            requirement: requirement,
            demands: [demand("reference.image.anchor")],
            candidates: [route]
        )
        #expect(legacy.map(\.deficits) == [[]])
        let unknown = ProductionRequirementResolverV1.slotAndModeEvaluations(
            requirement: requirement,
            demands: [demand("fixture.input.anchor")],
            candidates: [route]
        )
        #expect(unknown.first?.deficits.map(\.code) == [.inputSlotUnsupported])
    }

    private static let mode = "reference-to-video"

    private func slot(
        _ id: String,
        _ modality: AssetPhysicalModalityV1,
        order: Int
    ) -> ProductionInputSlotCapabilityV1 {
        ProductionInputSlotCapabilityV1(
            id: id, modality: modality, modeIDs: [Self.mode], requestOrder: order,
            countsTowardModalityBudget: true, countsTowardTotalBudget: true,
            countsTowardCombinedDuration: modality != .image
        )
    }

    private func demandObject(role: String, modality: String) -> [String: Any] {
        [
            "id": "street", "asset_path": "bible/street.png", "modality": modality,
            "semantic_job_id": role, "is_required": true, "priority": 0,
            "preservation_scope_ids": [], "exclusion_demand_ids": [],
            "input_slot_id": CoreReferenceInputSlotIDV1.referenceImage,
            "mode_id": Self.mode, "identity_lock": false,
            "entity_id": "main_street", "canon_ids": [],
        ]
    }

    private func generatedInput(
        demands: [[String: Any]],
        modes: [String] = [Self.mode],
        coreInputs: [String: String] = [:]
    ) throws -> PipelineExecutionShotInput {
        let value: [String: Any] = [
            "id": "s001",
            "source_mode": ExecutionSourceModeV1.generated.rawValue,
            "start_state": ["summary": "The street is empty.", "entity_state_ids": []],
            "end_state": ["summary": "The mouse crosses the street.", "entity_state_ids": []],
            "blocking": [],
            "timed_action_beats": [],
            "acceptance": [["id": "street", "requirement": "The street stays recognizable.", "severity": "required"]],
            "generation_requirement": [
                "modality_id": "video",
                "mode_ids": modes,
                "duration": ["allows_automatic": true],
                "requires_output_audio": false,
            ],
            "core_inputs": coreInputs,
            "reference_demands": demands,
        ]
        return try JSONDecoder().decode(
            PipelineExecutionShotInput.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }

    private func videoRoute(
        _ offeringID: String,
        inputKinds: [String],
        slots: [ProductionInputSlotCapabilityV1],
        imageCapacity: Int = 3
    ) -> ProductionRouteCandidateV1 {
        let origin = ResolvedCapabilityOriginV1(kind: .exact, profileID: "fixture-\(offeringID)")
        func value<Value>(_ value: Value) -> ResolvedCapabilityValueV1<Value>
        where Value: Codable & Sendable & Equatable {
            ResolvedCapabilityValueV1(value: value, semantics: .hardAPILimit, origin: origin, evidence: [])
        }
        let profile = ResolvedCapabilityProfileV1(
            requestedIdentity: nil,
            resolvedIdentity: nil,
            defensiveProfileID: nil,
            researchNeeded: false,
            fields: ResolvedCapabilityFieldsV1(
                integers: [
                    CapabilityFieldIDV1.referenceImages: value(imageCapacity),
                    CapabilityFieldIDV1.referenceVideos: value(3),
                    CapabilityFieldIDV1.referenceAudios: value(3),
                    CapabilityFieldIDV1.totalReferences: value(9),
                ],
                strings: [
                    CapabilityFieldIDV1.modes: value([Self.mode]),
                    CapabilityFieldIDV1.inputKinds: value(inputKinds),
                ]
            )
        )
        return ProductionRouteCandidateV1(
            capabilities: ResolvedOfferingCapabilityProfileV1(
                offering: CapabilityOfferingIdentityV1(
                    providerID: "fixture",
                    offeringID: offeringID,
                    endpointID: "\(offeringID)-endpoint",
                    catalogModelID: "fixture/\(offeringID)",
                    modality: .video
                ),
                intrinsic: profile,
                effective: profile
            ),
            providerActivated: true,
            liveAvailable: true,
            inputSlots: slots
        )
    }

    @Test("Writer and route failures name the field, the rule and the resolution")
    func structuredFailureDescriptions() {
        let coreInputs = PipelineExecutionPlanComposerError.invalidCoreInputs("shot-002").localizedDescription
        #expect(coreInputs.contains("execution_shots[shot-002].core_inputs"))
        #expect(coreInputs.contains("keyframe_strategy"))
        let coreReference = AssetGraphValidationError.invalidCoreReference("street").localizedDescription
        #expect(coreReference.contains("street"))
        #expect(coreReference.contains(CoreReferenceInputSlotIDV1.referenceImage))
        let dropped = ReferencePlanValidationErrorV2.requiredDemandDropped("street").localizedDescription
        #expect(dropped.contains("list_models.production_routes"))
        let mismatch = ConditioningStrategyValidationErrorV1.strategyMismatch("shot-002").localizedDescription
        #expect(mismatch.contains(CoreReferenceSemanticJobIDV1.referenceAnchor))
    }

    @Test("Discovered anchor slot is the slot real reference-image routes offer")
    func discoveredAnchorSlotIsRoutable() throws {
        let resolver = try #require(CatalogCapabilityRuntime.resolver)
        let anchor = try #require(
            PipelineExecutionIdentifierContract.discovery["reference_anchor"] as? [String: String]
        )
        let slotID = try #require(anchor["input_slot_id"])
        let frameSlots: Set<String> = [CoreReferenceInputSlotIDV1.firstFrame, CoreReferenceInputSlotIDV1.lastFrame]
        let imageReferenceSlots = FalModelRegistry.entries
            .flatMap { (try? ModelCatalog.offeringCapabilities(for: $0, resolver: resolver)) ?? [] }
            .filter { $0.offering.modality == .video }
            .flatMap { ModelCatalog.inputSlots(capabilities: $0) }
            .filter { $0.modality == .image && !frameSlots.contains($0.id) }
        #expect(!imageReferenceSlots.isEmpty)
        #expect(imageReferenceSlots.allSatisfy { $0.id == slotID })
    }

    @Test("Offered approval expires on artifact or lineage changes")
    func reviewBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("brief.yaml")
        let original = Data("approved creative direction".utf8)
        try original.write(to: file)
        let fingerprint = GateArtifactFingerprint(path: "brief.yaml", sha256: FileDigest.sha256(of: original), lineageSHA256: nil)
        #expect(fingerprint.matches(dataRoot: root))
        try Data("changed direction".utf8).write(to: file)
        #expect(!fingerprint.matches(dataRoot: root))
        try original.write(to: file)
        let lineage = PipelineLayout.url(PipelineLayout.lineageFile, in: root)
        try FileManager.default.createDirectory(at: lineage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new lineage".utf8).write(to: lineage)
        #expect(!fingerprint.matches(dataRoot: root))
    }

    @Test("Attention belongs to one pending review and never revives after acknowledgement")
    func attentionLifecycle() throws {
        let contract = try JSONDecoder().decode(ContractData.self, from: Data(#"{"phases":{"treatment":{"surface":"prose","task_class":"review"},"brief":{"surface":"prose","task_class":"review"}}}"#.utf8))
        let first = GateApproval(phase: "treatment")
        #expect(CockpitReviewAttention.titles(approval: first, acknowledged: [], contract: contract, surfaces: []) == ["Treatment"])
        let seen: Set<String> = [first.id]
        #expect(CockpitReviewAttention.titles(approval: first, acknowledged: seen, contract: contract, surfaces: []).isEmpty)
        #expect(CockpitReviewAttention.titles(approval: nil, acknowledged: seen, contract: contract, surfaces: []).isEmpty)
        let revision = GateApproval(phase: "treatment")
        #expect(CockpitReviewAttention.titles(approval: revision, acknowledged: seen, contract: contract, surfaces: []) == ["Treatment"])
        #expect(PipelineSurfaceRouting.route(for: "brief", contract: contract, availablePackSurfaces: [])?.destination == .tab(.story))
        #expect(CockpitTab.visibleTabs.contains(.storyboard))
    }

    @Test("Revising approved work is distinct from approving its contents")
    func revisionDecision() {
        let approval = GateApproval(phase: "storyboard", action: .rewind(gatesSHA256: "old", phases: ["storyboard", "bible"]))
        #expect(approval.isRewind)
        #expect(approval.decisionTitle == "Revise from Storyboard")
        #expect(approval.scoped(to: UUID()).action == approval.action)
        #expect(!approval.matchesRequest(GateApproval(phase: "storyboard")))
    }
}
