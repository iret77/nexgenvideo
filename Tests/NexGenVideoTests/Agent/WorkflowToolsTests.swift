import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine
@testable import MusicvideoPlugin

/// M7: the production-pipeline (engine) tools driven through ToolExecutor against a temp scaffolded
/// project. Each tool is passed an explicit `project_dir` (the harness editor has no open project),
/// exercising the same native NexGenEngine paths the `nexgen` MCP will call. Return shapes are
/// asserted against the Python `mcp_server` contract (and, for state, the committed golden's keys).
@MainActor
@Suite("Workflow (engine) tools")
struct WorkflowToolsTests {

    /// A throwaway scaffolded project; returns (harness, dataRoot, cleanup-root).
    private func scaffold(
        enforceHardGates: Bool = false,
        providerActivation: @escaping () -> ProviderActivation = {
            ProviderActivation.current()
        },
        productionRouteCandidates: @escaping ProductionRouteCandidateProvider = {
            ModelCatalog.shared.productionRouteCandidates(activation: $0)
        }
    ) throws -> (ToolHarness, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-tools-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo", mode: .beat)
        return (
            ToolHarness(
                enforceHardGates: enforceHardGates,
                providerActivation: providerActivation,
                productionRouteCandidates: productionRouteCandidates
            ),
            dataRoot,
            tmp
        )
    }

    private func falRoutingDependencies() -> (
        activation: ProviderActivation,
        candidates: ProductionRouteCandidateProvider
    ) {
        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries)
        let activation = ProviderActivation(active: [
            ProviderActivation.Key(provider: .fal, transport: .api),
        ])
        return (
            activation,
            { catalog.productionRouteCandidates(activation: $0) }
        )
    }

    private func hybridRoutingDependencies() -> (
        activation: ProviderActivation,
        candidates: ProductionRouteCandidateProvider
    ) {
        let modelID = "fixture-video-edit"
        let endpoint = "generate_video"
        let videoCaps = VideoCaps(
            durations: [4],
            resolutions: ["1080p"],
            aspectRatios: ["16:9"],
            supportsFirstFrame: false,
            supportsLastFrame: false,
            maxReferenceImages: 0,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: 0,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "video",
            requiresSourceVideo: true,
            requiresReferenceImage: false
        )
        let resolvedVideo = ResolvedVideoOfferingCapabilitiesV1(
            videoCapabilities: videoCaps,
            supportsNativeAudio: false
        )
        let offer = ProviderOffer(
            provider: .higgsfield,
            transport: .mcp,
            providerRef: endpoint,
            modelParam: modelID,
            mcpMediaRoles: ["video"],
            productionInputPolicy: resolvedVideo.inputPolicy,
            resolvedVideoCapabilities: resolvedVideo
        )
        let offering = CatalogOfferingIdentity.make(
            offer: offer,
            modelID: modelID,
            modality: .video
        )
        let evidence = CapabilityEvidenceV1(
            sourceTitle: "Fixture MCP video-edit schema",
            observedAt: "2026-08-31T00:00:00Z",
            kind: .providerSchema,
            confidence: 1
        )
        let exactOrigin = ResolvedCapabilityOriginV1(
            kind: .exact,
            profileID: "fixture-video-edit"
        )
        let endpointOrigin = ResolvedCapabilityOriginV1(
            kind: .endpointOverlay,
            profileID: "fixture-video-edit-endpoint",
            endpointID: endpoint
        )
        func value<Value>(
            _ value: Value,
            semantics: CapabilityValueSemanticsV1 = .hardAPILimit,
            origin: ResolvedCapabilityOriginV1
        ) -> ResolvedCapabilityValueV1<Value>
        where Value: Codable & Sendable & Equatable {
            ResolvedCapabilityValueV1(
                value: value,
                semantics: semantics,
                origin: origin,
                evidence: [evidence]
            )
        }
        func fields(origin: ResolvedCapabilityOriginV1) -> ResolvedCapabilityFieldsV1 {
            ResolvedCapabilityFieldsV1(
                integers: [
                    CapabilityFieldIDV1.visibleCharacters: value(0, origin: origin),
                    CapabilityFieldIDV1.referenceImages: value(0, origin: origin),
                    CapabilityFieldIDV1.referenceVideos: value(0, origin: origin),
                    CapabilityFieldIDV1.referenceAudios: value(0, origin: origin),
                    CapabilityFieldIDV1.totalReferences: value(0, origin: origin),
                ],
                decimals: [
                    CapabilityFieldIDV1.durationMinimum: value(4.0, origin: origin),
                    CapabilityFieldIDV1.durationMaximum: value(4.0, origin: origin),
                ],
                booleans: [
                    CapabilityFieldIDV1.nativeAudio: value(false, origin: origin),
                    CapabilityFieldIDV1.firstFrame: value(false, origin: origin),
                    CapabilityFieldIDV1.lastFrame: value(false, origin: origin),
                    CapabilityFieldIDV1.sourceVideo: value(true, origin: origin),
                    CapabilityFieldIDV1.sourceVideoRequired: value(true, origin: origin),
                    CapabilityFieldIDV1.framesCountTowardImageReferenceLimit:
                        value(false, origin: origin),
                    CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit:
                        value(false, origin: origin),
                ],
                strings: [
                    CapabilityFieldIDV1.modes: value(
                        ["video-to-video"],
                        semantics: .supportedSet,
                        origin: origin
                    ),
                    CapabilityFieldIDV1.aspectRatios: value(
                        ["16:9"],
                        semantics: .supportedSet,
                        origin: origin
                    ),
                    CapabilityFieldIDV1.resolutions: value(
                        ["1080p"],
                        semantics: .supportedSet,
                        origin: origin
                    ),
                ],
                integerLists: [
                    CapabilityFieldIDV1.durationValues: value(
                        [4],
                        semantics: .supportedSet,
                        origin: origin
                    ),
                ]
            )
        }
        let capability = ResolvedOfferingCapabilityProfileV1(
            offering: offering,
            intrinsic: ResolvedCapabilityProfileV1(
                requestedIdentity: nil,
                resolvedIdentity: nil,
                defensiveProfileID: nil,
                researchNeeded: false,
                fields: fields(origin: exactOrigin)
            ),
            effective: ResolvedCapabilityProfileV1(
                requestedIdentity: nil,
                resolvedIdentity: nil,
                defensiveProfileID: nil,
                researchNeeded: false,
                fields: fields(origin: endpointOrigin)
            )
        )
        let editEntry = CatalogEntry(
            id: modelID,
            kind: .video,
            displayName: "Fixture Video Edit",
            allowedEndpoints: [endpoint],
            responseShape: .video,
            uiCapabilities: .video(videoCaps),
            offers: [offer],
            resolvedOfferingCapabilities: [capability]
        )
        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries + [editEntry])
        catalog.applyDiscovered([editEntry], for: .higgsfield)
        catalog.setProviderDiscoveryState(.ready(modelCount: 1), for: .higgsfield)
        let activation = ProviderActivation(active: [
            ProviderActivation.Key(provider: .fal, transport: .api),
            ProviderActivation.Key(provider: .higgsfield, transport: .mcp),
        ])
        return (
            activation,
            { catalog.productionRouteCandidates(activation: $0) }
        )
    }

    private func declineIntakeStep(
        _ id: String,
        pack: String = "musicvideo",
        dataRoot: URL
    ) throws {
        let loaded = try #require(PackCatalog.pack(named: pack))
        let manifest = try #require(HardStepManifest.load(pack: loaded))
        let step = try #require(manifest.allSteps.first { $0.id == id })
        try IntakeLedger.recordDecline(step, dataRoot: dataRoot)
    }

    /// Mark the given data root's project package (parent of `pipeline`) active with `pack` by writing
    /// its `ngv.json` — the same file `ProjectPluginSettings` reads. Proves the pack resolves from the
    /// project HOME, not the data root.
    @discardableResult
    private func activatePack(
        _ pack: String,
        dataRoot: URL
    ) throws -> ProjectPackBinding {
        // Packs load at runtime — register the loadable musicvideo pack (idempotent)
        // the way the host's PluginLoader does, so the workflow tools resolve it.
        PackCatalog.register(MusicvideoPack())
        let home = FrameInventory.projectHome(of: dataRoot)
        let loaded = try #require(PackCatalog.pack(named: pack))
        let binding = try #require(ProjectPackBinding(
            id: pack,
            version: loaded.version,
            projectSchema: "\(pack)/2.0.0"
        ))
        try ProjectPluginSettings.setActivePlugin(binding, projectURL: home)
        return binding
    }

    private func recordLineage(_ phase: String, dataRoot: URL) throws {
        PackCatalog.register(MusicvideoPack())
        let registry = PackCatalog.registry(activePack: "musicvideo")
        let provider = try #require(registry.phaseLineageProviders[phase])
        try PipelineLineageStore.record(
            phase: phase,
            snapshot: try provider(dataRoot),
            dataRoot: dataRoot
        )
    }

    private func recordAnalysisLineage(dataRoot: URL) throws {
        try recordLineage("analysis", dataRoot: dataRoot)
    }

    private func minimalShotlist(
        project: String = "demo",
        keyframeStrategy: KeyframeStrategy = .start,
        productionPlan: ShotProductionPlan? = nil,
        generator: String = "test"
    ) throws -> Shotlist {
        let shot = try Shot(
            id: "s001", section: "verse", timeStart: 0.0, timeEnd: 4.0, durationS: 4.0,
            type: .performance, description: "d", visualPrompt: "p", mood: "m",
            keyframeStrategy: keyframeStrategy,
            productionPlan: productionPlan
        )
        let song = try Song(title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: 4.0)
        return try Shotlist(
            schema_: shotlistSchemaVersion, mode: .section, project: project, song: song,
            generated: "2026-01-01", generator: generator, shots: [shot]
        )
    }

    private func generatedExecutionShotInput(
        id: String = "s001",
        duration: Double = 12,
        firstFrame: Bool = true
    ) -> [String: Any] {
        [
            "id": id,
            "source_mode": ExecutionSourceModeV1.generated.rawValue,
            "start_state": [
                "summary": "The shot begins.",
                "entity_state_ids": [],
            ],
            "end_state": [
                "summary": "The shot ends.",
                "entity_state_ids": [],
            ],
            "blocking": [],
            "timed_action_beats": [],
            "acceptance": [[
                "id": "accept-\(id)",
                "requirement": "Keep the composition intact.",
                "severity": "required",
            ]],
            "generation_requirement": [
                "modality_id": CapabilityModalityV1.video.rawValue,
                "mode_ids": [firstFrame ? "image-to-video" : "text-to-video"],
                "duration": [
                    "minimum_seconds": duration,
                    "maximum_seconds": duration,
                    "allows_automatic": false,
                ],
                "requires_output_audio": false,
            ],
            "core_inputs": firstFrame
                ? ["first_frame_mode_id": "image-to-video"]
                : [:],
            "reference_demands": [],
        ]
    }

    private func importedExecutionShotInput(id: String = "s001") -> [String: Any] {
        [
            "id": id,
            "source_mode": ExecutionSourceModeV1.imported.rawValue,
            "start_state": [
                "summary": "The shot begins.",
                "entity_state_ids": [],
            ],
            "end_state": [
                "summary": "The shot ends.",
                "entity_state_ids": [],
            ],
            "blocking": [],
            "timed_action_beats": [],
            "acceptance": [[
                "id": "accept-\(id)",
                "requirement": "Keep the composition intact.",
                "severity": "required",
            ]],
            "primary_action": "The performer enters the yard.",
            "camera": ["movement_id": "static"],
            "continuity_locks": [],
            "renderability": "green",
            "risks": [],
        ]
    }

    private func executionShotInput(_ shot: Shot) -> [String: Any] {
        var result: [String: Any] = [
            "id": shot.id,
            "source_mode": shot.sourceMode.rawValue,
            "start_state": [
                "summary": "The shot begins.",
                "entity_state_ids": [],
            ],
            "end_state": [
                "summary": "The shot ends.",
                "entity_state_ids": [],
            ],
            "blocking": [],
            "timed_action_beats": [],
            "acceptance": [[
                "id": "accept-\(shot.id)",
                "requirement": "Keep the composition intact.",
                "severity": "required",
            ]],
        ]
        switch shot.sourceMode {
        case .generated, .aiEnhanced:
            var coreInputs: [String: Any] = [:]
            let modeIDs: [String]
            if shot.sourceMode == .aiEnhanced {
                modeIDs = ["video-to-video"]
                coreInputs["source_video_mode_id"] = "video-to-video"
            } else if shot.chainWithPreviousEnd {
                modeIDs = ["image-to-video"]
                coreInputs["predecessor_last_frame_mode_id"] = "image-to-video"
            } else if shot.keyframeStrategy != .none {
                modeIDs = ["image-to-video"]
                coreInputs["first_frame_mode_id"] = "image-to-video"
                if shot.keyframeStrategy == .startEnd {
                    coreInputs["last_frame_mode_id"] = "image-to-video"
                }
            } else {
                modeIDs = ["text-to-video"]
            }
            result["generation_requirement"] = [
                "modality_id": CapabilityModalityV1.video.rawValue,
                "mode_ids": modeIDs,
                "duration": [
                    "minimum_seconds": shot.durationS,
                    "maximum_seconds": shot.durationS,
                    "allows_automatic": false,
                ],
                "requires_output_audio": false,
            ]
            result["core_inputs"] = coreInputs
            if shot.sourceMode == .generated {
                result["reference_demands"] = []
            }
        case .imported:
            result["primary_action"] = "The performer enters the yard."
            result["camera"] = ["movement_id": "static"]
            result["continuity_locks"] = []
            result["renderability"] = "green"
            result["risks"] = []
        }
        return result
    }

    private func publishExecutionShotlist(
        _ shotlist: Shotlist,
        dataRoot: URL
    ) throws -> [PipelineExecutionShotInput] {
        let audioURL = dataRoot.appendingPathComponent(shotlist.song.audioPath)
        let analysisURL = dataRoot.appendingPathComponent(shotlist.song.analysisPath)
        for (url, bytes) in [
            (audioURL, Data("audio".utf8)),
            (analysisURL, Data("{}".utf8)),
            (
                PipelineLayout.url(PipelineLayout.productionDesignFile, in: dataRoot),
                Data("production design".utf8)
            ),
            (
                PipelineLayout.url(PipelineLayout.treatmentCurrentFile, in: dataRoot),
                Data("treatment".utf8)
            ),
            (
                PipelineLayout.url(PipelineLayout.storyboardCurrentFile, in: dataRoot),
                Data("storyboard".utf8)
            ),
        ] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: url, options: .atomic)
        }
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        try store.save(
            try Brief(
                project: shotlist.project,
                generated: "2026-08-31T00:00:00Z",
                mission: .demo,
                targetPlatform: "Test",
                aspectRatio: .landscape16x9,
                projectMode: Mode.section.rawValue,
                conceptType: .abstract,
                visualMedium: .animation2d,
                visualMediumNotes: "Flat 2D animation",
                figures: .none,
                lyricsIntegration: .metaphorical
            ),
            to: PipelineLayout.briefFile
        )
        try store.save(
            try Bible(
                project: shotlist.project,
                generated: "2026-08-31T00:00:00Z",
                generator: "test"
            ),
            to: PipelineLayout.bibleFile
        )
        let objects = shotlist.shots.map(executionShotInput)
        let inputs = try JSONDecoder().decode(
            [PipelineExecutionShotInput].self,
            from: JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        )
        _ = try PipelineShotlistWriter.write(
            shotlist,
            executionInputs: inputs,
            dataRoot: dataRoot,
            declaredPack: nil
        )
        return inputs
    }

    private func prepareNativeSourceExecution(
        dataRoot: URL,
        chainedSuccessor: Bool = false
    ) throws -> [PipelineExecutionShotInput] {
        let plan = try ShotProductionPlan(
            primaryAction: "Hold the composition.",
            cameraMovement: .static,
            renderability: .green
        )
        let shots = try [
            Shot(
                id: "s001",
                section: "one",
                timeStart: 0,
                timeEnd: 4,
                durationS: 4,
                type: .performance,
                description: "First shot",
                visualPrompt: "First frame",
                mood: "calm",
                keyframeStrategy: .none,
                productionPlan: plan
            ),
            Shot(
                id: "s002",
                section: "two",
                timeStart: 4,
                timeEnd: 8,
                durationS: 4,
                type: .performance,
                description: "Second shot",
                visualPrompt: "Second frame",
                mood: "calm",
                keyframeStrategy: .none,
                chainWithPreviousEnd: chainedSuccessor,
                productionPlan: plan
            ),
        ]
        let shotlist = try Shotlist(
            schema_: shotlistSchemaVersion,
            mode: .section,
            project: "demo",
            song: try Song(
                title: "Song",
                audioPath: "audio/song.wav",
                analysisPath: "analysis/song.json",
                bpm: 120,
                durationS: 8
            ),
            generated: "2026-08-31T00:00:00Z",
            generator: "test",
            shots: shots
        )
        return try publishExecutionShotlist(shotlist, dataRoot: dataRoot)
    }

    private func recursiveFileBytes(in root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let path = String(url.path.dropFirst(root.path.count + 1))
            result[path] = try Data(contentsOf: url)
        }
        return result
    }

    private func addGeneratedVideo(
        _ id: String,
        at url: URL,
        to harness: ToolHarness,
        dataRoot: URL,
        model: String = "video-model",
        sourceVideoAssetId: String? = nil,
        shotId: String = "s001",
        currentRouting: PipelineProductionRouteSelection? = nil
    ) throws {
        try Data(id.utf8).write(to: url)
        let shot = try #require(
            try loadShotlist(dataRoot: dataRoot)?.shots.first {
                $0.id == shotId
            }
        )
        let requirements = shot.videoProductionPromptRequirements
            .joined(separator: ". ")
        let prompt = "Compiled provider prompt for \(id)."
            + (requirements.isEmpty ? "" : " \(requirements)")
        let selectedModel = currentRouting?.modelID ?? model
        let selectedRequirement = currentRouting?.requirement
        let duration = Int(
            (selectedRequirement?.duration?.preferredSeconds
                ?? selectedRequirement?.duration?.minimumSeconds
                ?? selectedRequirement?.duration?.maximumSeconds
                ?? 4).rounded()
        )
        var input = GenerationInput(
            prompt: prompt,
            model: selectedModel,
            duration: duration,
            aspectRatio: selectedRequirement?.aspectRatio ?? "16:9",
            resolution: selectedRequirement?.resolution
        )
        input.videoDuration = .seconds(duration)
        input.generateAudio = selectedRequirement?.requiresOutputAudio ?? false
        input.promptShotId = shotId
        input.promptProjectKey = dataRoot.standardizedFileURL
            .resolvingSymlinksInPath().path
        input.promptShotFingerprint = try PromptCompiler.shotFingerprint(shot)
        if let currentRouting {
            let (proof, submitted) = try currentRoutingProof(
                currentRouting,
                harness: harness,
                dataRoot: dataRoot
            )
            let grouped = Dictionary(
                grouping: submitted,
                by: { ProductionIdentifierNormalizerV1.canonical($0.semanticJobID) }
            )
            input.sourceVideoAssetId = grouped[
                CoreReferenceSemanticJobIDV1.sourceVideo
            ]?.first?.mediaAssetID
            input.startFrameAssetId = (
                grouped[CoreReferenceSemanticJobIDV1.predecessorLastFrame]
                    ?? grouped[CoreReferenceSemanticJobIDV1.firstFrame]
            )?.first?.mediaAssetID
            input.endFrameAssetId = grouped[
                CoreReferenceSemanticJobIDV1.lastFrame
            ]?.first?.mediaAssetID
            let ordinary = submitted.filter {
                ![
                    CoreReferenceSemanticJobIDV1.sourceVideo,
                    CoreReferenceSemanticJobIDV1.firstFrame,
                    CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                    CoreReferenceSemanticJobIDV1.lastFrame,
                ].contains(ProductionIdentifierNormalizerV1.canonical($0.semanticJobID))
            }
            input.referenceImageAssetIds = ordinary.filter {
                $0.modalityID == AssetPhysicalModalityV1.image.rawValue
            }.map(\.mediaAssetID)
            input.referenceVideoAssetIds = ordinary.filter {
                $0.modalityID == AssetPhysicalModalityV1.video.rawValue
            }.map(\.mediaAssetID)
            input.referenceAudioAssetIds = ordinary.filter {
                $0.modalityID == AssetPhysicalModalityV1.audio.rawValue
            }.map(\.mediaAssetID)
            input.productionRouting = proof
        } else {
            input.sourceVideoAssetId = sourceVideoAssetId
            input.productionRouting = PipelineProductionRoutingTests.generationInput(
                requirement: ProductionRequirementV1(
                    modalityID: CapabilityModalityV1.video.rawValue,
                    modeIDs: ["text-to-video"],
                    visibleEntityCount: 0,
                    duration: RequestedDurationV1(
                        preferredSeconds: 4,
                        minimumSeconds: 4,
                        maximumSeconds: 4
                    ),
                    aspectRatio: "16:9",
                    requiresOutputAudio: false
                ),
                modelID: model,
                projectID: "demo",
                shotID: shotId
            ).productionRouting
        }
        harness.editor.mediaAssets.append(
            MediaAsset(
                id: id,
                url: url,
                type: .video,
                name: id,
                generationInput: input
            )
        )
    }

    private func currentRoutingProof(
        _ selection: PipelineProductionRouteSelection,
        harness: ToolHarness,
        dataRoot: URL
    ) throws -> (
        ProductionGenerationRoutingProofV1,
        [ProductionGenerationRoutingBindingV1]
    ) {
        let offeringCapabilities = try #require(
            selection.target.binding?.resolvedVideoCapabilities
        )
        let (assetGraph, demandSet, _) = try PipelineProductionInputsWriter.load(
            shotID: selection.route.shotID,
            dataRoot: dataRoot
        )
        let submitted = try selection.referencePlan.bindings.map { binding in
            let plannedURL = try ProjectLocalFile.requireHash(
                binding.sha256,
                at: binding.path,
                dataRoot: dataRoot
            ).standardizedFileURL.resolvingSymlinksInPath()
            let media = try #require(harness.editor.mediaAssets.first {
                $0.url.standardizedFileURL.resolvingSymlinksInPath() == plannedURL
            })
            return ProductionGenerationRoutingBindingV1(
                demandID: binding.demandID,
                graphAssetID: binding.assetID,
                graphAssetVersion: binding.assetVersion,
                mediaAssetID: media.id,
                path: binding.path,
                sha256: binding.sha256,
                modalityID: binding.modality.rawValue,
                semanticJobID: binding.semanticJobID,
                inputSlotID: binding.inputSlotID,
                modeID: binding.modeID
            )
        }
        let capabilitiesData = try ReferencePlanCanonicalCodecV2.encode(
            offeringCapabilities
        )
        let proof = ProductionGenerationRoutingProofV1(
            projectID: selection.route.projectID,
            shotID: selection.route.shotID,
            modelID: selection.modelID,
            providerID: selection.target.provider.rawValue,
            transportID: selection.target.transport.rawValue,
            endpointID: selection.target.endpoint,
            modelParam: selection.target.binding?.modelParam,
            offeringID: selection.route.offering.offeringID,
            requirement: selection.requirement,
            route: selection.route,
            referencePlan: selection.referencePlan,
            routeArtifactSHA256: selection.routeArtifactSHA256,
            requirementSHA256: selection.route.requirementSHA256,
            capabilitiesSHA256: selection.route.capabilitiesSHA256,
            routeSHA256: selection.route.routeSHA256,
            referencePlanSHA256: selection.referencePlanSHA256,
            orderedBindingsSHA256: selection.orderedBindingsSHA256,
            orderedBindings: submitted,
            offeringCapabilities: offeringCapabilities,
            offeringCapabilitiesSHA256: FileDigest.sha256(of: capabilitiesData),
            historicalAssetGraph: assetGraph,
            historicalDemandSet: demandSet
        )
        return (proof, submitted)
    }

    private func addSourceVideo(
        _ id: String,
        at url: URL,
        to harness: ToolHarness
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(id.utf8).write(to: url)
        harness.editor.mediaAssets.append(
            MediaAsset(
                id: id,
                url: url,
                type: .video,
                name: id
            )
        )
    }

    private func addGeneratedImage(
        _ id: String,
        at url: URL,
        to harness: ToolHarness
    ) throws {
        try Data(id.utf8).write(to: url)
        let input = GenerationInput(
            prompt: "Compiled provider prompt for \(id).",
            model: "image-model",
            duration: 0,
            aspectRatio: "1:1"
        )
        harness.editor.mediaAssets.append(
            MediaAsset(
                id: id,
                url: url,
                type: .image,
                name: id,
                generationInput: input
            )
        )
    }

    private func writeMeasuredAnalysis(dataRoot: URL) throws -> URL {
        let audio = dataRoot.appendingPathComponent("audio/song.wav")
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stub".utf8).write(to: audio)
        let songHash = SHA256.hash(data: try Data(contentsOf: audio))
            .map { String(format: "%02x", $0) }
            .joined()
        let lyrics = "[Intro]\nopening line\n[Verse]\nverse line"
        let lyricsURL = dataRoot.appendingPathComponent("lyrics/lyrics.txt")
        try FileManager.default.createDirectory(
            at: lyricsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(lyrics.utf8).write(to: lyricsURL)
        let analysis = dataRoot.appendingPathComponent("analysis/song.json")
        try FileManager.default.createDirectory(
            at: analysis.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let alignmentSource = dataRoot.appendingPathComponent("analysis/stems/vocals.wav")
        try FileManager.default.createDirectory(
            at: alignmentSource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("measured-vocals".utf8).write(to: alignmentSource)
        let object: [String: Any] = [
            "schema": "analysis/v3",
            "project": "demo",
            "song_path": "audio/song.wav",
            "song_sha256": songHash,
            "sample_rate": 44_100,
            "duration_s": 12,
            "bpm": 120,
            "beats": [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
            "downbeats": [0.0, 2.0, 4.0],
            "sections": [
                [
                    "index": 0, "start": 0.0, "end": 4.0, "cluster": 0,
                    "label": "intro", "source": "measured_system_hierarchy", "confidence": 0.95,
                ],
                [
                    "index": 1, "start": 4.0, "end": 12.0, "cluster": 1,
                    "label": "verse", "source": "measured_system_hierarchy", "confidence": 0.95,
                ],
            ],
            "structure_candidates": [
                ["source": "librosa", "sections": [
                    ["index": 0, "start": 0.0, "end": 4.0, "cluster": 0],
                    ["index": 1, "start": 4.0, "end": 12.0, "cluster": 1],
                ]],
                ["source": "essentia", "sections": [
                    ["index": 0, "start": 0.0, "end": 4.0, "cluster": 0],
                    ["index": 1, "start": 4.0, "end": 12.0, "cluster": 1],
                ]],
            ],
            "structure_resolution": [
                "version": "adaptive-structure/v5",
                "status": "resolved",
                "method": "music_understanding_hierarchy",
                "detector_sources": ["apple_music_understanding"],
                "minimum_section_bars": 0,
                "candidate_boundary_count": 2,
                "consensus_boundary_count": 0,
                "alignment_marker_count": 2,
                "resolved_alignment_marker_count": 2,
                "alignment_timing_evidence": "recognized_speech",
                "accepted_boundary_count": 1,
                "discarded_boundary_count": 2,
                "boundary_evidence": [
                    [
                        "time": 0.0,
                        "kind": "system_hierarchy",
                        "detector_sources": ["apple_music_understanding"],
                        "lyric_marker": "intro",
                    ],
                    [
                        "time": 4.0,
                        "kind": "system_hierarchy",
                        "detector_sources": ["apple_music_understanding"],
                        "lyric_marker": "verse",
                    ],
                ],
                "hierarchy": [
                    "source": "apple_music_understanding",
                    "sections": [["start": 0.0, "end": 4.0], ["start": 4.0, "end": 12.0]],
                    "segments": [["start": 0.0, "end": 4.0], ["start": 4.0, "end": 12.0]],
                    "phrases": [["start": 0.0, "end": 4.0], ["start": 4.0, "end": 12.0]],
                ],
                "detail": "Measured system hierarchy.",
            ],
            "downbeat_source": "music-understanding",
            "pipeline_stages": ["structure", "music_understanding"],
            "stage_diagnostics": [[
                "stage": "music_understanding",
                "status": "succeeded",
                "detail": "Measured system hierarchy.",
            ], [
                "stage": "lyrics_alignment",
                "status": "succeeded",
                "detail": "Measured recognized-speech alignment.",
                "timing_evidence": "recognized_speech",
            ]],
            "alignment": [
                ["start": 0.0, "end": 1.0, "text": "opening line", "section_marker": "intro", "words": [
                    ["text": "opening", "start": 0.0, "end": 0.4, "score": 1.0],
                    ["text": "line", "start": 0.4, "end": 1.0, "score": 1.0],
                ]],
                ["start": 4.0, "end": 5.0, "text": "verse line", "section_marker": "verse", "words": [
                    ["text": "verse", "start": 4.0, "end": 4.4, "score": 1.0],
                    ["text": "line", "start": 4.4, "end": 5.0, "score": 1.0],
                ]],
            ],
            "interpretation": [
                "section_labels": [],
                "anomalies": [[
                    "kind": "boundary_divergence",
                    "time": "4.000",
                    "detail": "librosa vs essentia",
                ]],
                "overall_character": "",
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: analysis)
        try AnalysisMeasurementProofStore.save(
            AnalysisMeasurementProof(
                project: "demo",
                songSHA256: songHash,
                lyricsAlignment: AnalysisMeasurementProof.LyricsAlignmentProof(
                    sourcePath: "analysis/stems/vocals.wav",
                    sourceSHA256: try FileDigest.sha256(of: alignmentSource),
                    lyricsSHA256: AnalysisMeasurementProofStore.lyricsFingerprint(lyrics),
                    alignmentSHA256: try AnalysisMeasurementProofStore.alignmentFingerprint(
                        object
                    ),
                    timingEvidence: .recognizedSpeech,
                    timingMethod: nil,
                    markerCount: 2,
                    lyricTokenCount: 4,
                    matchedTokenCount: 4
                )
            ),
            dataRoot: dataRoot
        )
        try recordAnalysisLineage(dataRoot: dataRoot)
        return analysis
    }

    private func writeUnresolvedAnalysis(dataRoot: URL) throws -> URL {
        let url = try writeMeasuredAnalysis(dataRoot: dataRoot)
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["sections"] = [[
            "index": 0,
            "start": 0.0,
            "end": 12.0,
            "cluster": 0,
            "source": "unresolved_structure",
        ]]
        object["structure_candidates"] = [[
            "source": "librosa",
            "sections": [["index": 0, "start": 0.0, "end": 12.0, "cluster": 0]],
        ]]
        object["structure_resolution"] = [
            "version": "adaptive-structure/v5",
            "status": "needs_review",
            "method": "unresolved",
            "detector_sources": ["librosa"],
            "minimum_section_bars": 0,
            "candidate_boundary_count": 0,
            "consensus_boundary_count": 0,
            "alignment_marker_count": 0,
            "resolved_alignment_marker_count": 0,
            "accepted_boundary_count": 0,
            "discarded_boundary_count": 0,
            "boundary_evidence": [],
            "detail": "No complete system hierarchy is available.",
        ]
        object["alignment"] = []
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try recordAnalysisLineage(dataRoot: dataRoot)
        return url
    }

    private func validBriefArgs(dataRoot: URL) -> [String: Any] {
        [
            "project_dir": dataRoot.path,
            "mission": "single_release",
            "target_platform": "YouTube",
            "aspect_ratio": "16:9",
            "project_mode": "section",
            "concept_type": "narrative",
            "visual_medium": "live_action_realistic",
            "figures": "artist_only",
            "lyrics_integration": "literal",
        ]
    }

    private func writeApprovableBible(dataRoot: URL) throws {
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        try store.save(
            try Brief(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                mission: .demo,
                targetPlatform: "YouTube",
                aspectRatio: .landscape16x9,
                projectMode: "section",
                budgetEur: 50,
                conceptType: .narrative,
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                tone: [.quiet],
                figures: .none,
                lyricsIntegration: .metaphorical
            ),
            to: PipelineLayout.briefFile
        )
        try store.save(
            try ProductionDesign(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                colorScript: ["intro": "Muted blue dawn."]
            ),
            to: "production_design/production_design.yaml"
        )
        let steps = try (1...4).map { index in
            try Step(
                id: "intro.\(String(format: "%02d", index))",
                function: index == 1 ? .transition : .story,
                subject: "The performer holds opening pose \(index).",
                camera: "Wide static frame.",
                settingHint: "yard, from the gate",
                locationViewRequest: "wide",
                framing: "wide",
                cameraSetup: [
                    "height": "eye_level",
                    "angle": "frontal",
                    "lens_hint": "wide",
                ]
            )
        }
        try StoryboardStore.save(
            try Storyboard(
                meta: try StoryboardMeta(
                    project: "demo",
                    version: 1,
                    generated: "2026-07-26T00:00:00Z",
                    summaryOneline: "A restrained dawn."
                ),
                sections: [
                    try Section(
                        id: "intro",
                        label: "intro",
                        timeStart: 0,
                        timeEnd: 4,
                        energy: "low",
                        function: "aufbau",
                        steps: steps
                    ),
                ]
            ),
            to: dataRoot
        )

        let anchor = dataRoot.appendingPathComponent("bible/yard-wide.png")
        try FileManager.default.createDirectory(
            at: anchor.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("anchor".utf8).write(to: anchor)
        try store.save(
            try Bible(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                generator: "test",
                look: LookGuide(style: "restrained hand-drawn animation"),
                locations: [
                    try Location(
                        id: "yard",
                        name: "Schoolyard",
                        visualPrompt: "A quiet schoolyard at blue hour.",
                        sheets: ["wide": "bible/yard-wide.png"]
                    ),
                ]
            ),
            to: PipelineLayout.bibleFile
        )
        try savePipelineAssetProof(
            PipelineAssetProof(
                project: "demo",
                scope: "bible",
                entries: [
                    "bible/yard-wide.png": PipelineAssetProofEntry(
                        path: "bible/yard-wide.png",
                        sha256: try FileDigest.sha256(of: anchor),
                        providerPrompt: "Compiled sheet prompt",
                        generationModel: "image-model",
                        sourceMediaId: "generated-sheet"
                    ),
                ]
            ),
            dataRoot: dataRoot
        )
        try MusicvideoGateChecks.requireRealBible(dataRoot: dataRoot)
    }

    // MARK: - init_project → get_project_state

    @Test("init_project scaffolds a project and get_project_state matches the state.json golden keys")
    func initThenState() async throws {
        let (h, _, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        // init_project into a fresh home, then read its state.
        let freshHome = cleanup.appendingPathComponent("fresh", isDirectory: true)
        let initJSON = try await h.runOK("init_project", args: [
            "home_dir": freshHome.path, "name": "basic-project",
        ]) as? [String: Any]
        #expect(initJSON?["created"] as? Bool == true)
        #expect(initJSON?["project"] as? String == "basic-project")
        let dataRoot = try #require(initJSON?["data_root"] as? String)

        let state = try await h.runOK("get_project_state", args: ["project_dir": dataRoot]) as? [String: Any]
        // The committed golden's top-level keys (Tests/NexGenEngineTests/Goldens/basic-project/state.json).
        for key in ["project", "mode", "budget_eur", "budget_spent_eur", "budget_remaining_eur", "phases", "next_phase"] {
            #expect(state?[key] != nil, "state missing key \(key)")
        }
        #expect(state?["project"] as? String == "basic-project")
        #expect(state?["mode"] as? String == "beat")
        #expect(state?["next_phase"] as? String == "project_init")
        let phases = try #require(state?["phases"] as? [[String: Any]])
        #expect(phases.first?["phase"] as? String == "project_init")
        #expect(phases.first?["state"] as? String == "pending")
    }

    @Test("init_project on an existing project errors, not crashes")
    func initTwiceErrors() async throws {
        let (h, _, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.appendingPathComponent("dupe", isDirectory: true)
        _ = try await h.runOK("init_project", args: ["home_dir": home.path, "name": "x"])
        let result = await h.runRaw("init_project", args: ["home_dir": home.path, "name": "x"])
        #expect(result.isError)
    }

    @Test("init_project redirects an open saved package to its working copy")
    func initProjectCannotBypassWorkingCopy() async throws {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-init-working-\(UUID().uuidString)", isDirectory: true)
        let savedHome = cleanup.appendingPathComponent("Project.ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: savedHome)
        let h = ToolHarness()
        h.editor.projectURL = savedHome
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let liveHome = try #require(h.editor.workingRoot)

        _ = try await h.runOK("init_project", args: [
            "home_dir": savedHome.path,
            "name": "working-project",
        ])

        #expect(FileManager.default.fileExists(
            atPath: liveHome.appendingPathComponent("pipeline/project.yaml").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: savedHome.appendingPathComponent("pipeline/project.yaml").path
        ))
    }

    // MARK: - list_phases / get_ui_contract

    @Test("list_phases returns the ordered core pipeline")
    func listPhases() async throws {
        let h = ToolHarness()
        let phases = try await h.runOK("list_phases") as? [Any]
        #expect(phases?.first as? String == "project_init")
        #expect(phases?.last as? String == "render")
        #expect(phases?.count == coreGatePhases.count)
    }

    @Test("list_phases folds in the active pack's phases at their declared placement")
    func listPhasesWithPack() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)

        let phases = try await h.runOK("list_phases", args: ["project_dir": dataRoot.path]) as? [String]
        #expect(phases?.first == "project_init")
        #expect(phases?.contains("analysis") == true)  // the pack gate is present…
        // musicvideo declares `analysis` right after project_init (it gates before brief).
        #expect(phases?[1] == "analysis")
        #expect(phases?.dropFirst(2).first == "brief")  // analysis precedes brief
        #expect(phases?.count == coreGatePhases.count + 1)
    }

    @Test("get_project_state places the active pack's analysis gate before brief")
    func stateWithPack() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)

        let state = try await h.runOK("get_project_state", args: ["project_dir": dataRoot.path]) as? [String: Any]
        let phases = try #require(state?["phases"] as? [[String: Any]])
        let names = phases.compactMap { $0["phase"] as? String }
        #expect(names.contains("analysis"))
        // analysis is inserted right after project_init, ahead of brief — not appended at the end.
        let analysisIdx = try #require(names.firstIndex(of: "analysis"))
        let briefIdx = try #require(names.firstIndex(of: "brief"))
        #expect(names[analysisIdx - 1] == "project_init")
        #expect(analysisIdx < briefIdx)
    }

    @Test("get_ui_contract exposes surfaces and a per-phase entry")
    func uiContract() async throws {
        let h = ToolHarness()
        let contract = try await h.runOK("get_ui_contract") as? [String: Any]
        #expect(contract?["surfaces"] as? [String] == ["choice", "prose", "review"])
        let phases = try #require(contract?["phases"] as? [String: Any])
        let brief = try #require(phases["brief"] as? [String: Any])
        #expect(brief["surface"] as? String == "prose")
        #expect(brief["task_class"] as? String == "interpretation")
    }

    // MARK: - approve_gate / set_gate_state / rewind round-trip

    @Test("approve_gate, set_gate_state, and rewind round-trip through gates.yaml")
    func gateRoundTrip() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let dir = dataRoot.path

        // Gates approve in order — project_init before brief. approve_gate now surfaces a user
        // confirmation; runGate stands in for the user tapping Approve.
        _ = try await h.runGateOK("approve_gate", args: ["project_dir": dir, "phase": "project_init"])
        let approved = try await h.runGateOK("approve_gate", args: ["project_dir": dir, "phase": "brief", "notes": "ok"]) as? [String: Any]
        #expect(approved?["approved"] as? Bool == true)
        #expect(approved?["phase"] as? String == "brief")
        #expect(approved?["notes"] as? String == "ok")

        // set_gate_state to needs_revision keeps the phase blocked (approved == false). This is NOT an
        // approval, so it writes straight through with no confirmation — plain runOK.
        let revised = try await h.runOK("set_gate_state", args: ["project_dir": dir, "phase": "brief", "state": "needs_revision", "notes": "redo"]) as? [String: Any]
        #expect(revised?["state"] as? String == "needs_revision")
        #expect(revised?["approved"] as? Bool == false)

        // Re-approve brief, then approve in order through treatment; rewind to brief resets brief + after.
        _ = try await h.runGateOK("approve_gate", args: ["project_dir": dir, "phase": "brief"])
        _ = try await h.runGateOK("approve_gate", args: ["project_dir": dir, "phase": "production_design"])
        _ = try await h.runGateOK("approve_gate", args: ["project_dir": dir, "phase": "treatment"])
        var rewindMarkedProjectChanged = false
        h.editor.onPipelineChanged = {
            rewindMarkedProjectChanged = true
        }
        let rewound = try await h.runOK("rewind", args: ["project_dir": dir, "target_phase": "brief"]) as? [String: Any]
        #expect(rewound?["target"] as? String == "brief")
        #expect(rewindMarkedProjectChanged)
        let reset = try #require(rewound?["reset_phases"] as? [String])
        #expect(reset.first == "brief")
        #expect(reset.contains("treatment"))
        #expect(reset.last == "render")
    }

    @Test("approve_gate is hard-blocked for analysis until a real artifact exists")
    func analysisGateHardBlocked() async throws {
        let (h, dataRoot, cleanup) = try scaffold(enforceHardGates: true)
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let binding = try activatePack("musicvideo", dataRoot: dataRoot)
        try FileManager.default.createDirectory(
            at: dataRoot.appendingPathComponent("audio"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dataRoot.appendingPathComponent("lyrics"),
            withIntermediateDirectories: true
        )
        try Data("track".utf8).write(
            to: dataRoot.appendingPathComponent("audio/song.wav")
        )
        try Data("lyrics".utf8).write(
            to: dataRoot.appendingPathComponent("lyrics/lyrics.txt")
        )

        // Approve the predecessor first, so the analysis block is attributable to the ARTIFACT hard
        // gate (no measured beats/downbeats), not merely to ordering.
        let ok = try await h.runGateOK("approve_gate", args: ["project_dir": dataRoot.path, "phase": "project_init"]) as? [String: Any]
        #expect(ok?["approved"] as? Bool == true)

        let nativeReadiness = await NativeGateWriter.controlReadiness(
            projectDir: FrameInventory.projectHome(of: dataRoot),
            phase: "analysis",
            declaredPack: "musicvideo",
            declaredBinding: binding,
            executionCoordinator: h.editor.pipelinePhaseRunCoordinator
        ).approval
        #expect(!nativeReadiness.isReady)
        #expect(nativeReadiness.blocker?.contains("no analysis artifact") == true)
        do {
            try await NativeGateWriter.approve(
                projectDir: FrameInventory.projectHome(of: dataRoot),
                phase: "analysis",
                declaredPack: "musicvideo",
                declaredBinding: binding,
                executionCoordinator: h.editor.pipelinePhaseRunCoordinator
            )
            Issue.record("Native approval ignored its blocked readiness")
        } catch let error as NativeGateWriter.WriteError {
            #expect(error.localizedDescription == nativeReadiness.blocker)
        } catch {
            Issue.record("Native approval exposed an unexpected error type: \(error)")
        }

        // No analysis artifact → approve_gate("analysis") is refused by requireRealAnalysis (points at
        // run_phase). The hard gate is enforced BEFORE the user is ever asked to confirm — the tool
        // errors without surfacing an approval card.
        let blocked = await h.runGate("approve_gate", args: ["project_dir": dataRoot.path, "phase": "analysis"])
        #expect(blocked.isError == true)
        #expect(ToolHarness.textOf(blocked).contains("run_phase"))
        #expect(h.editor.agentService.pendingGateApproval == nil, "a blocked gate must not surface an approval card")

        // set_gate_state to an approved state is refused the same way — no bypass, no card.
        let blocked2 = await h.runGate("set_gate_state", args: [
            "project_dir": dataRoot.path, "phase": "analysis", "state": "approved",
        ])
        #expect(blocked2.isError == true)
        #expect(ToolHarness.textOf(blocked2).contains("run_phase"))

        _ = try writeMeasuredAnalysis(dataRoot: dataRoot)
        _ = try await h.runOK(
            "write_analysis_interpretation",
            args: [
                "project_dir": dataRoot.path,
                "tempo_multiplier": 1.0,
                "section_labels": [
                    [
                        "index": 0,
                        "label": "intro",
                        "confidence": 0.9,
                    ],
                    [
                        "index": 1,
                        "label": "verse",
                        "confidence": 0.9,
                    ],
                ],
                "anomalies": [],
                "overall_character": "Measured pulse with a clear opening and development.",
            ]
        )
        let ready = await NativeGateWriter.controlReadiness(
            projectDir: FrameInventory.projectHome(of: dataRoot),
            phase: "analysis",
            declaredPack: "musicvideo",
            declaredBinding: binding,
            executionCoordinator: h.editor.pipelinePhaseRunCoordinator
        ).approval
        #expect(ready.isReady)
        #expect(ready.blocker == nil)
    }

    @Test("gate mutations are refused while a phase runner is active")
    func gateMutationBlockedDuringPhaseRun() async throws {
        let (h, dataRoot, cleanup) = try scaffold(enforceHardGates: true)
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let binding = try activatePack("musicvideo", dataRoot: dataRoot)
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&gates, phase: "project_init")
        try store.save(gates, to: PipelineLayout.gatesFile)
        _ = try writeMeasuredAnalysis(dataRoot: dataRoot)
        _ = try await h.runOK(
            "write_analysis_interpretation",
            args: [
                "project_dir": dataRoot.path,
                "tempo_multiplier": 1.0,
                "section_labels": [
                    [
                        "index": 0,
                        "label": "intro",
                        "confidence": 0.9,
                    ],
                    [
                        "index": 1,
                        "label": "verse",
                        "confidence": 0.9,
                    ],
                ],
                "anomalies": [],
                "overall_character": "Measured pulse with a clear opening and development.",
            ]
        )
        try await h.editor.pipelineAgentHarness.recordPhaseMutation(
            phase: "analysis",
            dataRoot: dataRoot,
            declaredPack: "musicvideo",
            declaredBinding: binding
        )
        let latch = PhaseRunnerLatch()
        async let phaseRun = h.editor.pipelinePhaseRunCoordinator.run(
            projectRoot: dataRoot,
            phase: "analysis",
            sourceFilename: "song.wav",
            runner: { _ in latch.block() },
            progressRunner: nil,
            state: h.editor.pipelinePhaseExecution
        )
        await latch.waitUntilEntered()

        let blocked = await h.runGate("approve_gate", args: [
            "project_dir": dataRoot.path,
            "phase": "analysis",
        ])

        #expect(blocked.isError)
        #expect(
            ToolHarness.textOf(blocked)
                .contains("while analysis is running")
        )
        #expect(h.editor.agentService.pendingGateApproval == nil)

        let stateBlocked = await h.runRaw("set_gate_state", args: [
            "project_dir": dataRoot.path,
            "phase": "analysis",
            "state": "needs_revision",
        ])
        #expect(stateBlocked.isError)
        #expect(
            ToolHarness.textOf(stateBlocked)
                .contains("while analysis is running")
        )

        let rewindBlocked = await h.runRaw("rewind", args: [
            "project_dir": dataRoot.path,
            "target_phase": "project_init",
        ])
        #expect(rewindBlocked.isError)
        #expect(
            ToolHarness.textOf(rewindBlocked)
                .contains("while analysis is running")
        )

        let nativeReadiness = await NativeGateWriter.controlReadiness(
            projectDir: FrameInventory.projectHome(of: dataRoot),
            phase: "analysis",
            declaredPack: "musicvideo",
            declaredBinding: binding,
            executionCoordinator: h.editor.pipelinePhaseRunCoordinator
        ).approval
        #expect(!nativeReadiness.isReady)
        #expect(nativeReadiness.blocker?.contains("while analysis is running") == true)

        let writerBlocked = await h.runRaw("attach_song", args: [
            "project_dir": dataRoot.path,
            "path": cleanup.appendingPathComponent("replacement.wav").path,
        ])
        #expect(writerBlocked.isError)
        #expect(
            ToolHarness.textOf(writerBlocked)
                .contains("while analysis is running")
        )

        do {
            try NativeGateWriter.rewind(
                projectDir: FrameInventory.projectHome(of: dataRoot),
                targetPhase: "project_init",
                declaredPack: nil,
                executionCoordinator: h.editor.pipelinePhaseRunCoordinator
            )
            Issue.record("The native gate writer rewound an active phase")
        } catch {
            #expect(
                error.localizedDescription
                    .contains("while analysis is running")
            )
        }
        latch.allowCompletion()
        #expect(await phaseRun == .completed)
        let settledReadiness = await NativeGateWriter.controlReadiness(
            projectDir: FrameInventory.projectHome(of: dataRoot),
            phase: "analysis",
            declaredPack: "musicvideo",
            declaredBinding: binding,
            executionCoordinator: h.editor.pipelinePhaseRunCoordinator
        )
        #expect(settledReadiness.mutations.isReady)
        #expect(settledReadiness.approval.isReady)
    }

    @Test("completed pipeline keeps rewind controls available without an approval target")
    func completedPipelineKeepsRewindAvailable() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        for phase in PhaseOrder.merged(packPlacements: []) {
            GatesOperations.approve(&gates, phase: phase)
        }
        try store.save(gates, to: PipelineLayout.gatesFile)

        let readiness = await NativeGateWriter.controlReadiness(
            projectDir: FrameInventory.projectHome(of: dataRoot),
            phase: nil,
            declaredPack: nil,
            executionCoordinator: h.editor.pipelinePhaseRunCoordinator
        )

        #expect(readiness.mutations.isReady)
        #expect(!readiness.approval.isReady)
        #expect(readiness.approval.blocker?.contains("already approved") == true)
    }

    @Test("Brief work is structurally blocked until its host-owned intake is resolved")
    func briefWaitsForCreativeIntake() async throws {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-intake-\(UUID().uuidString)", isDirectory: true)
        let package = cleanup.appendingPathComponent("Project.ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: package)
        PackCatalog.register(MusicvideoPack())
        let packageDataRoot = try ProjectScaffold.initProject(
            home: package,
            name: "demo",
            mode: .beat,
            extraDirs: PackCatalog.projectDirs(activePack: "musicvideo")
        )
        _ = try activatePack("musicvideo", dataRoot: packageDataRoot)

        let store = YAMLArtifactStore(dataRoot: packageDataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        GatesOperations.approve(&gates, phase: "project_init")
        GatesOperations.approve(&gates, phase: "analysis")
        try store.save(gates, to: PipelineLayout.gatesFile)

        let h = ToolHarness(enforceHardGates: true)
        h.editor.projectURL = package
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let dataRoot = try #require(
            h.editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        )
        let reconciliation = h.editor.pipelineAgentHarness.reconcile(editor: h.editor)
        #expect(!reconciliation.isReady)
        #expect(h.editor.agentService.pendingDialog?.title == "Existing story")
        let blocked = await h.runRaw(
            "write_brief",
            args: validBriefArgs(dataRoot: dataRoot)
        )

        #expect(blocked.isError)
        #expect(ToolHarness.textOf(blocked).contains("host-owned Existing story card"))

        let blockedDialog = await h.runRaw(
            "show_dialog",
            args: [
                "title": "Choose a story direction",
                "sections": [[
                    "id": "direction",
                    "label": "Direction",
                    "type": "choices",
                    "options": [
                        ["id": "one", "label": "One"],
                        ["id": "two", "label": "Two"],
                    ],
                ]],
            ]
        )
        #expect(blockedDialog.isError)
        #expect(ToolHarness.textOf(blockedDialog).contains("host-owned Existing story card"))
    }

    @Test("list_project_files + copy_project_file stage files and refuse to escape the project")
    func projectFileTools() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let importDir = dataRoot.appendingPathComponent("import/characters/mouse", isDirectory: true)
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: importDir.appendingPathComponent("face.png"))

        let list = try #require(try await h.runOK("list_project_files", args: [
            "project_dir": dataRoot.path, "subdir": "import",
        ]) as? [String: Any])
        #expect((list["files"] as? [String])?.contains("import/characters/mouse/face.png") == true)

        _ = try await h.runOK("copy_project_file", args: [
            "project_dir": dataRoot.path,
            "from": "import/characters/mouse/face.png", "to": "bible/refs/mouse/face.png",
        ])
        let copiedURL = dataRoot.appendingPathComponent("bible/refs/mouse/face.png")
        #expect(try String(contentsOf: copiedURL, encoding: .utf8) == "x")                 // bytes copied
        #expect(try String(contentsOf: importDir.appendingPathComponent("face.png"), encoding: .utf8) == "x")  // source intact (copy)

        // A lexically escaping path is refused.
        let escape = await h.runRaw("copy_project_file", args: [
            "project_dir": dataRoot.path, "from": "import/characters/mouse/face.png", "to": "../escape.png",
        ])
        #expect(escape.isError == true)

        let canonicalArtifact = await h.runRaw("copy_project_file", args: [
            "project_dir": dataRoot.path,
            "from": "import/characters/mouse/face.png",
            "to": PipelineLayout.bibleFile,
        ])
        #expect(canonicalArtifact.isError == true)

        let canonicalSource = await h.runRaw("copy_project_file", args: [
            "project_dir": dataRoot.path,
            "from": PipelineLayout.gatesFile,
            "to": "bible/refs/mouse/gates.png",
        ])
        #expect(canonicalSource.isError == true)

        // A symlink escaping the project is refused too.
        let outside = cleanup.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dataRoot.appendingPathComponent("import/link"), withDestinationURL: outside)
        let symlinkEscape = await h.runRaw("copy_project_file", args: [
            "project_dir": dataRoot.path, "from": "import/characters/mouse/face.png", "to": "import/link/stolen.png",
        ])
        #expect(symlinkEscape.isError == true)
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("stolen.png").path))
    }

    @Test("copy_project_file stages generated media with exact pipeline provenance")
    func projectMediaCopyRecordsProvenance() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let source = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent("sheet.png")
        try addGeneratedImage("sheet-media", at: source, to: h)

        let result = try #require(try await h.runOK(
            "copy_project_file",
            args: [
                "project_dir": dataRoot.path,
                "media": "sheet-media",
                "to": "bible/mouse/front.png",
            ]
        ) as? [String: Any])
        #expect(result["generated_provenance"] as? Bool == true)

        let proof = try loadPipelineAssetProof(
            dataRoot: dataRoot,
            scope: "bible"
        )
        let entry = try #require(
            proof.entries["bible/mouse/front.png"]
        )
        let staged = dataRoot.appendingPathComponent(
            "bible/mouse/front.png"
        )
        #expect(entry.sha256 == (try FileDigest.sha256(of: staged)))
        #expect(entry.generationModel == "image-model")
        #expect(entry.sourceMediaId == "sheet-media")
    }

    @Test("Scene3D extraction refuses path-bearing identifiers and external panoramas")
    func scene3dExtractionStaysInsidePipeline() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        let identifierEscape = await h.runRaw(
            "extract_scene3d_povs",
            args: [
                "project_dir": dataRoot.path,
                "location_id": "../../outside",
            ]
        )
        #expect(identifierEscape.isError)

        let panoramaEscape = await h.runRaw(
            "extract_scene3d_povs",
            args: [
                "project_dir": dataRoot.path,
                "location_id": "studio",
                "panorama": "../outside.png",
            ]
        )
        #expect(panoramaEscape.isError)
    }

    @Test("set_gate_state rejects an unknown state")
    func setGateStateBadValue() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let result = await h.runRaw("set_gate_state", args: ["project_dir": dataRoot.path, "phase": "brief", "state": "vibes"])
        #expect(result.isError)
    }

    @Test("rewind rejects unreadable live format settings")
    func rewindRejectsUnreadableFormatSettings() async throws {
        let (h, savedDataRoot, cleanup) = try scaffold()
        try activatePack("musicvideo", dataRoot: savedDataRoot)
        let package = FrameInventory.projectHome(of: savedDataRoot)
        try Fixtures.prepareProjectPackage(at: package)
        h.editor.projectURL = package
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let workingHome = try #require(h.editor.workingRoot)
        let workingDataRoot = try #require(
            DataRootResolver.dataRoot(of: workingHome)
        )
        let gatesURL = workingDataRoot.appendingPathComponent(
            PipelineLayout.gatesFile
        )
        let gatesBefore = try Data(contentsOf: gatesURL)
        try Data("{broken".utf8).write(
            to: workingHome.appendingPathComponent("ngv.json"),
            options: .atomic
        )

        let result = await h.runRaw("rewind", args: [
            "project_dir": workingDataRoot.path,
            "target_phase": "project_init",
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("unreadable"))
        #expect(try Data(contentsOf: gatesURL) == gatesBefore)

        let mismatchedSettings = try JSONSerialization.data(
            withJSONObject: ["activePlugin": "other"]
        )
        try mismatchedSettings.write(
            to: workingHome.appendingPathComponent("ngv.json"),
            options: .atomic
        )
        let mismatch = await h.runRaw("rewind", args: [
            "project_dir": workingDataRoot.path,
            "target_phase": "project_init",
        ])
        #expect(mismatch.isError)
        #expect(ToolHarness.textOf(mismatch).contains("musicvideo"))
        #expect(ToolHarness.textOf(mismatch).contains("other"))
        #expect(try Data(contentsOf: gatesURL) == gatesBefore)
    }

    @Test("same-ID pack schema changes block agent and native gate mutations byte-exactly")
    func gateMutationsRejectSameIDPackSchemaChange() async throws {
        let (h, savedDataRoot, cleanup) = try scaffold()
        let trusted = try activatePack("musicvideo", dataRoot: savedDataRoot)
        let package = FrameInventory.projectHome(of: savedDataRoot)
        try Fixtures.prepareProjectPackage(at: package)
        h.editor.projectURL = package
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let workingHome = try #require(h.editor.workingRoot)
        let workingDataRoot = try #require(
            DataRootResolver.dataRoot(of: workingHome)
        )
        let gatesURL = PipelineLayout.url(
            PipelineLayout.gatesFile,
            in: workingDataRoot
        )
        let gatesBefore = try Data(contentsOf: gatesURL)
        let sibling = try #require(ProjectPackBinding(
            id: trusted.id,
            version: trusted.version,
            projectSchema: "musicvideo/2.0.1"
        ))
        try ProjectPluginSettings.setActivePlugin(
            sibling,
            projectURL: workingHome
        )

        let agentResult = await h.runRaw("rewind", args: [
            "project_dir": workingDataRoot.path,
            "target_phase": "project_init",
        ])
        #expect(agentResult.isError)
        #expect(try Data(contentsOf: gatesURL) == gatesBefore)

        #expect(throws: NativeGateWriter.WriteError.self) {
            try NativeGateWriter.rewind(
                projectDir: workingHome,
                targetPhase: "project_init",
                declaredPack: trusted.id,
                declaredBinding: trusted,
                executionCoordinator: h.editor.pipelinePhaseRunCoordinator
            )
        }
        #expect(try Data(contentsOf: gatesURL) == gatesBefore)
    }

    @Test("gate approval rechecks the exact pack binding before the click writes")
    func deferredGateApprovalRejectsBindingChange() async throws {
        let (h, savedDataRoot, cleanup) = try scaffold()
        let trusted = try activatePack("musicvideo", dataRoot: savedDataRoot)
        let package = FrameInventory.projectHome(of: savedDataRoot)
        try Fixtures.prepareProjectPackage(at: package)
        let track = savedDataRoot.appendingPathComponent("audio/song.wav")
        try FileManager.default.createDirectory(
            at: track.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeStub(track)
        try declineIntakeStep(
            "project_init.lyrics",
            dataRoot: savedDataRoot
        )
        h.editor.projectURL = package
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let workingHome = try #require(h.editor.workingRoot)
        let workingDataRoot = try #require(
            DataRootResolver.dataRoot(of: workingHome)
        )
        let gatesURL = PipelineLayout.url(
            PipelineLayout.gatesFile,
            in: workingDataRoot
        )
        let gatesBefore = try Data(contentsOf: gatesURL)
        let pending = await h.runRaw("approve_gate", args: [
            "project_dir": workingDataRoot.path,
            "phase": "project_init",
        ])
        #expect(!pending.isError)
        #expect(h.editor.agentService.pendingGateApproval?.declaredBinding == trusted)

        let sibling = try #require(ProjectPackBinding(
            id: trusted.id,
            version: "0.4.5",
            projectSchema: trusted.projectSchema
        ))
        try ProjectPluginSettings.setActivePlugin(
            sibling,
            projectURL: workingHome
        )
        let result = try #require(
            await h.editor.agentService.resolveGate(.approved)
        )
        #expect(result.isError)
        #expect(try Data(contentsOf: gatesURL) == gatesBefore)
    }

    @Test("agent and native rewinds reject a declared but unwired pack")
    func rewindsRejectUnwiredPack() async throws {
        let (h, savedDataRoot, cleanup) = try scaffold()
        let package = FrameInventory.projectHome(of: savedDataRoot)
        let pack = "unwired-\(UUID().uuidString.lowercased())"
        let binding = try #require(ProjectPackBinding(
            id: pack,
            version: "1.0.0",
            projectSchema: "\(pack)/1.0.0"
        ))
        try ProjectPluginSettings.setActivePlugin(binding, projectURL: package)
        try Fixtures.prepareProjectPackage(at: package)
        h.editor.projectURL = package
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let workingHome = try #require(h.editor.workingRoot)
        let workingDataRoot = try #require(
            DataRootResolver.dataRoot(of: workingHome)
        )
        let gatesURL = workingDataRoot.appendingPathComponent(
            PipelineLayout.gatesFile
        )
        let gatesBefore = try Data(contentsOf: gatesURL)

        let agentResult = await h.runRaw("rewind", args: [
            "project_dir": workingDataRoot.path,
            "target_phase": "project_init",
        ])
        #expect(agentResult.isError)
        #expect(ToolHarness.textOf(agentResult).contains("isn't the pack code active"))
        #expect(try Data(contentsOf: gatesURL) == gatesBefore)

        let agentStateResult = await h.runRaw("set_gate_state", args: [
            "project_dir": workingDataRoot.path,
            "phase": "project_init",
            "state": "needs_revision",
        ])
        #expect(agentStateResult.isError)
        #expect(ToolHarness.textOf(agentStateResult).contains("isn't the pack code active"))
        #expect(try Data(contentsOf: gatesURL) == gatesBefore)

        #expect(throws: NativeGateWriter.WriteError.self) {
            try NativeGateWriter.rewind(
                projectDir: workingHome,
                targetPhase: "project_init",
                declaredPack: pack,
                executionCoordinator: h.editor.pipelinePhaseRunCoordinator
            )
        }
        await #expect(throws: NativeGateWriter.WriteError.self) {
            try await NativeGateWriter.setState(
                projectDir: workingHome,
                phase: "project_init",
                state: .needsRevision,
                declaredPack: pack,
                executionCoordinator: h.editor.pipelinePhaseRunCoordinator
            )
        }
        #expect(try Data(contentsOf: gatesURL) == gatesBefore)
    }

    // MARK: - Ledger set / lock / remove

    @Test("an explicit saved-package path is redirected to the open working copy")
    func savedProjectDirCannotBypassWorkingCopy() async throws {
        let (h, savedDataRoot, cleanup) = try scaffold()
        let home = FrameInventory.projectHome(of: savedDataRoot)
        try Fixtures.prepareProjectPackage(at: home)
        h.editor.projectURL = home
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let liveDataRoot = try #require(
            h.editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        )

        _ = try await h.runOK("set_ledger_attribute", args: [
            "project_dir": savedDataRoot.path,
            "kind": "look",
            "key": "palette",
            "tag": "working only",
        ])

        #expect(FileManager.default.fileExists(
            atPath: liveDataRoot.appendingPathComponent(PipelineLayout.ledgerFile).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: savedDataRoot.appendingPathComponent(PipelineLayout.ledgerFile).path
        ))
    }

    @Test("ledger set, lock, and remove round-trip; a locked attribute refuses removal")
    func ledgerRoundTrip() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let dir = dataRoot.path

        let set = try await h.runOK("set_ledger_attribute", args: [
            "project_dir": dir, "kind": "look", "key": "palette", "tag": "warm amber",
        ]) as? [String: Any]
        #expect(set?["tag"] as? String == "warm amber")
        #expect(set?["directive"] as? String == "warm amber")  // directive defaults to tag
        #expect(set?["locked"] as? Bool == false)

        let locked = try await h.runOK("lock_ledger_attribute", args: [
            "project_dir": dir, "kind": "look", "key": "palette",
        ]) as? [String: Any]
        #expect(locked?["locked"] as? Bool == true)

        // Locked → removal refused (the lock guard).
        let refused = await h.runRaw("remove_ledger_attribute", args: ["project_dir": dir, "kind": "look", "key": "palette"])
        #expect(refused.isError)

        // Unlock, then remove.
        _ = try await h.runOK("lock_ledger_attribute", args: ["project_dir": dir, "kind": "look", "key": "palette", "locked": false])
        let removed = try await h.runOK("remove_ledger_attribute", args: ["project_dir": dir, "kind": "look", "key": "palette"]) as? [String: Any]
        #expect(removed?["removed"] as? Bool == true)

        // get_ledger reflects the empty ledger.
        let ledger = try await h.runOK("get_ledger", args: ["project_dir": dir]) as? [String: Any]
        #expect(ledger?["schema"] as? String == "ledger/v1")
        let objects = try #require(ledger?["objects"] as? [String: Any])
        #expect(objects["look"] == nil)
    }

    @Test("set_ledger_attribute for an entity kind without object_id errors")
    func ledgerEntityNeedsObjectId() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let result = await h.runRaw("set_ledger_attribute", args: [
            "project_dir": dataRoot.path, "kind": "character", "key": "wardrobe", "tag": "red jacket",
        ])
        #expect(result.isError)
    }

    @Test("ledger mutation refuses and preserves a corrupt ledger")
    func corruptLedgerIsNotOverwritten() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let ledgerURL = PipelineLayout.url(PipelineLayout.ledgerFile, in: dataRoot)
        let corrupt = Data("objects: [broken".utf8)
        try corrupt.write(to: ledgerURL)

        let result = await h.runRaw("set_ledger_attribute", args: [
            "project_dir": dataRoot.path,
            "kind": "look",
            "key": "palette",
            "tag": "warm amber",
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Nothing was written"))
        #expect(try Data(contentsOf: ledgerURL) == corrupt)
    }

    // MARK: - resolve_model

    @Test("resolve_model returns the task-class floor and one-step escalation")
    func resolveModel() async throws {
        let h = ToolHarness()
        let distill = try await h.runOK("resolve_model", args: ["task_class": "distill"]) as? [String: Any]
        #expect(distill?["tier"] as? String == "fast")
        #expect(distill?["effort"] as? String == "low")
        #expect(distill?["escalated"] as? Bool == false)
        #expect(distill?["model"] as? String == ModelRouter.defaultManifest["fast"])

        let escalated = try await h.runOK("resolve_model", args: ["task_class": "distill", "escalate": true]) as? [String: Any]
        #expect(escalated?["tier"] as? String == "medium")
        #expect(escalated?["escalated"] as? Bool == true)
    }

    @Test("resolve_model rejects an unknown task class")
    func resolveModelUnknown() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("resolve_model", args: ["task_class": "vibes"])
        #expect(result.isError)
    }

    // MARK: - run_sanity on a minimal shotlist

    @Test("run_sanity refuses a project with no shotlist")
    func sanityNoShotlist() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let report = await h.runRaw(
            "run_sanity",
            args: ["project_dir": dataRoot.path]
        )
        #expect(report.isError)
        #expect(ToolHarness.textOf(report).contains("No shot list exists"))
    }

    @Test("run_sanity on a minimal shotlist returns findings with the four contract fields")
    func sanityWithShotlist() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)

        let report = try await h.runOK("run_sanity", args: ["project_dir": dataRoot.path]) as? [String: Any]
        #expect(report?["project"] as? String == "demo")
        #expect(report?["path"] as? String == PipelineLayout.sanityReportFile)
        #expect((report?["input_fingerprint"] as? String)?.isEmpty == false)
        #expect(FileManager.default.fileExists(
            atPath: PipelineLayout.url(
                PipelineLayout.sanityReportFile,
                in: dataRoot
            ).path
        ))
        let findings = try #require(report?["findings"] as? [[String: Any]])
        // The "p" prompt is too short → PROMPT_TOO_SHORT proves core checks ran.
        #expect(findings.contains { ($0["code"] as? String) == "PROMPT_TOO_SHORT" })
        for f in findings {
            #expect(f["level"] != nil)
            #expect((f["code"] as? String)?.isEmpty == false)
            #expect((f["message"] as? String)?.isEmpty == false)
            #expect(f.keys.contains("shot_id"))  // present, possibly NSNull
        }
    }

    @Test("run_sanity activates reusable profiles from the pack and brief")
    func sanityActivatesProductionProfiles() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)
        try YAMLArtifactStore(dataRoot: dataRoot).save(
            try Brief(
                project: "demo",
                generated: "2026-08-08T00:00:00Z",
                mission: .artPiece,
                targetPlatform: "Festival",
                aspectRatio: .landscape16x9,
                projectMode: "section",
                budgetEur: 50,
                conceptType: .narrative,
                visualMedium: .liveActionRealistic,
                tone: [.quiet],
                figures: .othersOnly,
                lyricsIntegration: .metaphorical
            ),
            to: PipelineLayout.briefFile
        )
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)

        let report = try await h.runOK(
            "run_sanity",
            args: ["project_dir": dataRoot.path]
        ) as? [String: Any]
        let findings = try #require(report?["findings"] as? [[String: Any]])
        let codes = Set(findings.compactMap { $0["code"] as? String })
        #expect(codes.contains("PRODUCTION_PLAN_MISSING"))
        #expect(!codes.contains("NARRATIVE_BEAT_MISSING"))
        #expect(!codes.contains("NARRATIVE_ACTION_MISSING"))
        #expect(!codes.contains("NARRATIVE_CONTEXT_MISSING"))
        #expect(!codes.contains("NARRATIVE_CONSEQUENCE_MISSING"))
    }

    @Test("agent prompt includes only host-activated production profiles")
    func agentPromptUsesActiveProductionProfiles() throws {
        let (_, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        let order = PhaseOrder.merged(
            packPlacements: PackCatalog.registry(activePack: "musicvideo")
                .phasePlacements
        )
        for phase in order.prefix(while: { $0 != "shotlist" }) {
            GatesOperations.approve(&gates, phase: phase)
        }
        try store.save(gates, to: PipelineLayout.gatesFile)

        func saveBrief(conceptType: ConceptType) throws {
            try store.save(
                try Brief(
                    project: "demo",
                    generated: "2026-08-10T00:00:00Z",
                    mission: .artPiece,
                    targetPlatform: "Festival",
                    aspectRatio: .landscape16x9,
                    projectMode: "section",
                    budgetEur: 50,
                    conceptType: conceptType,
                    visualMedium: .liveActionRealistic,
                    tone: [.quiet],
                    figures: .artistOnly,
                    lyricsIntegration: .metaphorical
                ),
                to: PipelineLayout.briefFile
            )
        }

        try saveBrief(conceptType: .performance)
        let performancePrompt = try #require(
            try PipelineAgentHarness().agentPrompt(dataRoot: dataRoot)
        )
        #expect(performancePrompt.contains("Core production profile: generative_film"))
        #expect(!performancePrompt.contains("Core production profile: narrative_storytelling"))

        try saveBrief(conceptType: .narrative)
        let narrativePrompt = try #require(
            try PipelineAgentHarness().agentPrompt(dataRoot: dataRoot)
        )
        #expect(narrativePrompt.contains("Core production profile: generative_film"))
        #expect(narrativePrompt.contains("Core production profile: narrative_storytelling"))

        try Data("concept_type: [unterminated".utf8).write(
            to: PipelineLayout.url(PipelineLayout.briefFile, in: dataRoot)
        )
        #expect(throws: ToolError.self) {
            _ = try PipelineAgentHarness().agentPrompt(dataRoot: dataRoot)
        }
    }

    // MARK: - estimate_cost / render manifest / show_artifact / run_phase / get_bible

    @Test("estimate_cost returns the spent/remaining budget picture")
    func estimateCost() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let cost = try await h.runOK("estimate_cost", args: ["project_dir": dataRoot.path]) as? [String: Any]
        #expect(cost?["project"] as? String == "demo")
        #expect(cost?["budget_eur"] as? Double == 50.0)
        #expect(cost?["spent_eur"] as? Double == 0.0)
        #expect(cost?["remaining_eur"] as? Double == 50.0)
        #expect(cost?["over_budget"] as? Bool == false)
        #expect(cost?.keys.contains("next_phase") == true)
    }

    @Test("storyboard writer rejects declared direction-only set anchors")
    func storyboardWriterRejectsDirectionOnlySetAnchors() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)
        let steps: [[String: Any]] = (1...4).map { index in
            var blocking: [[String: Any]] = []
            if index == 1 {
                blocking = [[
                    "character_ref": "performer",
                    "position": "left third",
                    "pose": "standing",
                    "gaze": "toward camera",
                    "relation_to_set": "beside the screen edge",
                    "set_anchor": "screen-left edge",
                ]]
            }
            return [
                "id": "intro.\(String(format: "%02d", index))",
                "function": "story",
                "source_mode": "generated",
                "subject": "The performer waits.",
                "camera": "Wide static frame.",
                "setting_hint": "yard, from the gate",
                "location_view_request": "wide",
                "character_view_request": [],
                "prop_request": [],
                "framing": "wide",
                "visible_zones": ["screen-left edge"],
                "zone_introduces": index == 1 ? ["screen-left edge"] : [],
                "camera_setup": [
                    "height": "eye_level",
                    "angle": "frontal",
                    "lens_hint": "wide",
                ],
                "character_blocking": blocking,
            ]
        }

        let result = await h.runRaw("write_storyboard", args: [
            "project_dir": dataRoot.path,
            "origin": "agent_proposal",
            "summary_oneline": "The performer waits.",
            "sections": [[
                "id": "intro",
                "label": "intro",
                "time_start": 0,
                "time_end": 12,
                "energy": "low",
                "function": "aufbau",
                "steps": steps,
            ]],
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("concrete set_anchor"))
        #expect(try StoryboardStore.load(dataRoot: dataRoot, version: .current) == nil)
    }

    @Test("typed planning writers persist engine-valid artifacts")
    func typedPlanningWritersPersistArtifacts() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)

        _ = try writeMeasuredAnalysis(dataRoot: dataRoot)
        try YAMLArtifactStore(dataRoot: dataRoot).save(
            try Brief(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                mission: .demo,
                targetPlatform: "YouTube",
                aspectRatio: .landscape16x9,
                projectMode: "section",
                budgetEur: 50,
                conceptType: .narrative,
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                figures: .none,
                lyricsIntegration: .metaphorical
            ),
            to: PipelineLayout.briefFile
        )
        try recordAnalysisLineage(dataRoot: dataRoot)
        try recordLineage("brief", dataRoot: dataRoot)

        _ = try await h.runOK("write_production_design", args: [
            "project_dir": dataRoot.path,
            "visual_medium": "2d_animation",
            "refs": [],
            "color_script": [[
                "section": "intro",
                "description": "Muted blue dawn.",
            ]],
        ])
        let design = try YAMLArtifactStore(dataRoot: dataRoot).load(
            ProductionDesign.self,
            at: "production_design/production_design.yaml"
        )
        #expect(design.project == "demo")
        #expect(design.colorScript["intro"] == "Muted blue dawn.")
        try recordLineage("production_design", dataRoot: dataRoot)

        _ = try await h.runOK("write_treatment", args: [
            "project_dir": dataRoot.path,
            "origin": "agent_proposal",
            "summary_oneline": "A quiet dawn begins the film.",
            "body_markdown": "The empty yard holds until the performer arrives.",
        ])
        let treatment = try TreatmentStore.load(dataRoot: dataRoot)
        #expect(treatment.meta.project == "demo")
        #expect(treatment.meta.version == 1)
        try recordLineage("treatment", dataRoot: dataRoot)

        let storyboardSteps: [[String: Any]] = (1...4).map { index in
            [
                "id": "intro.\(String(format: "%02d", index))",
                "function": index == 1 ? "transition" : "story",
                "source_mode": "generated",
                "subject": "The empty yard waits before sunrise.",
                "camera": "Wide static frame.",
                "setting_hint": "yard, from the gate",
                "location_view_request": "wide",
                "character_view_request": [],
                "prop_request": [],
                "framing": "wide",
                "visible_zones": ["yard_main"],
                "zone_introduces": index == 1 ? ["yard_main"] : [],
                "camera_setup": [
                    "height": "eye_level",
                    "angle": "frontal",
                    "lens_hint": "wide",
                ],
                "character_blocking": [],
            ]
        }
        _ = try await h.runOK("write_storyboard", args: [
            "project_dir": dataRoot.path,
            "origin": "agent_proposal",
            "summary_oneline": "The yard wakes.",
            "sections": [[
                "id": "intro",
                "label": "intro",
                "time_start": 0,
                "time_end": 12,
                "energy": "low",
                "function": "aufbau",
                "steps": storyboardSteps,
            ]],
        ])
        let storyboard = try #require(
            try StoryboardStore.load(
                dataRoot: dataRoot,
                version: .current
            )
        )
        #expect(storyboard.sections.first?.steps.first?.framing == "wide")
        try recordLineage("storyboard", dataRoot: dataRoot)

        let anchor = dataRoot.appendingPathComponent("bible/yard-wide.png")
        try FileManager.default.createDirectory(
            at: anchor.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("anchor".utf8).write(to: anchor)
        try savePipelineAssetProof(
            PipelineAssetProof(
                project: "demo",
                scope: "bible",
                entries: [
                    "bible/yard-wide.png": PipelineAssetProofEntry(
                        path: "bible/yard-wide.png",
                        sha256: try FileDigest.sha256(of: anchor),
                        providerPrompt: "Compiled provider prompt",
                        generationModel: "image-model",
                        sourceMediaId: "yard-wide"
                    ),
                ]
            ),
            dataRoot: dataRoot
        )
        let location: [String: Any] = [
            "id": "yard",
            "name": "Schoolyard",
            "visual_prompt": "A quiet hand-drawn schoolyard at blue hour.",
            "attributes": [],
            "hard_recognition_trait": "red gate",
            "reference_images": [],
            "sheets": [["view": "wide", "path": "bible/yard-wide.png"]],
            "view_purpose": [["view": "wide", "purpose": "establishing"]],
            "floorplan": "",
            "zones": [[
                "id": "yard_main",
                "description": "Main yard",
                "status": "clean",
                "bible_assets": ["bible/yard-wide.png"],
            ]],
            "scene3d": [
                "panorama": "",
                "provider": "",
                "povs": [],
            ],
        ]
        _ = try await h.runOK("write_bible", args: [
            "project_dir": dataRoot.path,
            "look": ["style": "restrained hand-drawn animation"],
            "characters": [],
            "ensembles": [],
            "props": [],
            "locations": [location],
        ])
        let bible = try #require(try loadBible(dataRoot: dataRoot))
        #expect(bible.locations.first?.sheets["wide"] == "bible/yard-wide.png")
        try recordLineage("bible", dataRoot: dataRoot)

        let shot: [String: Any] = [
            "id": "s001",
            "section": "intro",
            "time_start": 0,
            "time_end": 12,
            "duration_s": 12,
            "type": "performance",
            "source_mode": "generated",
            "description": "The performer enters the yard.",
            "visual_prompt": "At t=0 the empty hand-drawn yard waits in a wide blue-hour frame.",
            "mood": "restrained",
            "character_refs": [],
            "character_views": [],
            "keyframe_strategy": "start",
            "visible_zones": ["yard_main"],
            "zone_introduces": [],
            "character_blocking": [],
            "prop_refs": [],
            "prop_views": [],
            "redo": false,
            "scene_video_provider": "fal",
            "seedance_input_mode": "keyframe",
            "reference_image_refs": [],
            "chain_with_previous_end": false,
            "transition_in": "hard_cut",
            "transition_out": "hard_cut",
            "production_plan": [
                "primary_action": "The performer enters the yard.",
                "camera_movement": "static",
                "narrative_beat": "establish",
                "renderability": "green",
                "risks": [],
                "continuity_locks": [],
                "blocking_anchors": [],
            ],
        ]
        let generatedExecution = generatedExecutionShotInput()
        var missingPlanShot = shot
        missingPlanShot.removeValue(forKey: "production_plan")
        let missingPlan = await h.runRaw("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [missingPlanShot],
            "execution_shots": [generatedExecution],
        ])
        #expect(missingPlan.isError)
        #expect(ToolHarness.textOf(missingPlan).contains("production_plan"))
        #expect(latestShotlistVersion(dataRoot: dataRoot) == nil)

        var invalidShot = shot
        var invalidPlan = try #require(
            invalidShot["production_plan"] as? [String: Any]
        )
        invalidPlan.removeValue(forKey: "narrative_beat")
        invalidShot["production_plan"] = invalidPlan
        let missingBeat = await h.runRaw("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [invalidShot],
            "execution_shots": [generatedExecution],
        ])
        #expect(missingBeat.isError)
        #expect(ToolHarness.textOf(missingBeat).contains("narrative_beat"))

        var oversizedShot = shot
        var oversizedPlan = try #require(
            oversizedShot["production_plan"] as? [String: Any]
        )
        oversizedPlan["primary_action"] = String(
            repeating: "x",
            count: ShotProductionPlan.singleDirectiveMaximumLength + 1
        )
        oversizedShot["production_plan"] = oversizedPlan
        let oversized = await h.runRaw("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [oversizedShot],
            "execution_shots": [generatedExecution],
        ])
        #expect(oversized.isError)
        #expect(
            ToolHarness.textOf(oversized).contains(
                "expected at most \(ShotProductionPlan.singleDirectiveMaximumLength) character(s)"
            )
        )

        var unanchoredShot = shot
        unanchoredShot["character_refs"] = ["performer"]
        unanchoredShot["character_blocking"] = [[
            "character_ref": "performer",
            "position": "near the doorway",
            "pose": "standing",
            "gaze": "toward the yard",
            "relation_to_set": "beside the doorway",
        ]]
        var unanchoredPlan = try #require(unanchoredShot["production_plan"] as? [String: Any])
        unanchoredPlan["blocking_anchors"] = [[
            "character_ref": "performer",
            "set_anchor": "   ",
        ]]
        unanchoredShot["production_plan"] = unanchoredPlan
        let unanchored = await h.runRaw("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [unanchoredShot],
            "execution_shots": [generatedExecution],
        ])
        #expect(unanchored.isError)
        #expect(ToolHarness.textOf(unanchored).contains("required pattern"))

        var directionOnlyShot = unanchoredShot
        directionOnlyShot["character_blocking"] = [[
            "character_ref": "performer",
            "position": "near the doorway",
            "pose": "standing",
            "gaze": "toward the yard",
            "relation_to_set": "beside the doorway",
        ]]
        var directionOnlyPlan = try #require(
            directionOnlyShot["production_plan"] as? [String: Any]
        )
        directionOnlyPlan["blocking_anchors"] = [[
            "character_ref": "performer",
            "set_anchor": "screen-right",
        ]]
        directionOnlyShot["production_plan"] = directionOnlyPlan
        let directionOnly = await h.runRaw("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [directionOnlyShot],
            "execution_shots": [generatedExecution],
        ])
        #expect(directionOnly.isError)
        #expect(ToolHarness.textOf(directionOnly).contains("required pattern"))

        var disguisedDirectionShot = unanchoredShot
        disguisedDirectionShot["visible_zones"] = ["screen-left edge"]
        var disguisedDirectionPlan = try #require(
            disguisedDirectionShot["production_plan"] as? [String: Any]
        )
        disguisedDirectionPlan["blocking_anchors"] = [[
            "character_ref": "performer",
            "set_anchor": "screen-left edge",
        ]]
        disguisedDirectionShot["production_plan"] = disguisedDirectionPlan
        let disguisedDirection = await h.runRaw("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [disguisedDirectionShot],
            "execution_shots": [generatedExecution],
        ])
        #expect(disguisedDirection.isError)
        #expect(
            ToolHarness.textOf(disguisedDirection).contains(
                "prop_refs or visible_zones"
            )
        )

        var undeclaredAnchorShot = unanchoredShot
        var undeclaredAnchorPlan = try #require(
            undeclaredAnchorShot["production_plan"] as? [String: Any]
        )
        undeclaredAnchorPlan["blocking_anchors"] = [[
            "character_ref": "performer",
            "set_anchor": "upper left",
        ]]
        undeclaredAnchorShot["production_plan"] = undeclaredAnchorPlan
        let undeclaredAnchor = await h.runRaw("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [undeclaredAnchorShot],
            "execution_shots": [generatedExecution],
        ])
        #expect(undeclaredAnchor.isError)
        #expect(ToolHarness.textOf(undeclaredAnchor).contains("prop_refs or visible_zones"))

        var missingRelationShot = unanchoredShot
        missingRelationShot["character_blocking"] = [[
            "character_ref": "performer",
            "position": "near the doorway",
            "pose": "standing",
            "gaze": "toward the yard",
            "relation_to_set": "",
        ]]
        var missingRelationPlan = try #require(
            missingRelationShot["production_plan"] as? [String: Any]
        )
        missingRelationPlan["blocking_anchors"] = [[
            "character_ref": "performer",
            "set_anchor": "hall doorway",
        ]]
        missingRelationShot["production_plan"] = missingRelationPlan
        let missingRelation = await h.runRaw("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [missingRelationShot],
            "execution_shots": [generatedExecution],
        ])
        #expect(missingRelation.isError)
        #expect(ToolHarness.textOf(missingRelation).contains("expected at least 1 character"))

        _ = try await h.runOK("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [shot],
            "execution_shots": [generatedExecution],
        ])
        let shotlist = try #require(try loadShotlist(dataRoot: dataRoot))
        #expect(shotlist.project == "demo")
        #expect(shotlist.song.bpm == 120)
        #expect(shotlist.shots.map(\.id) == ["s001"])

        var importedShot = shot
        importedShot["source_mode"] = "imported"
        importedShot["keyframe_strategy"] = "none"
        let importedWithPlan = await h.runRaw("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [importedShot],
            "execution_shots": [importedExecutionShotInput()],
        ])
        #expect(importedWithPlan.isError)
        #expect(ToolHarness.textOf(importedWithPlan).contains("production_plan"))
        #expect(latestShotlistVersion(dataRoot: dataRoot) == 1)

        importedShot.removeValue(forKey: "production_plan")
        _ = try await h.runOK("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [importedShot],
            "execution_shots": [importedExecutionShotInput()],
        ])
        let importedShotlist = try #require(try loadShotlist(dataRoot: dataRoot))
        #expect(importedShotlist.shots.first?.sourceMode == .imported)
        #expect(importedShotlist.shots.first?.productionPlan == nil)
    }

    @Test("planning writers reject project-path symlink escapes")
    func planningWriterRejectsSymlinkEscape() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let outside = cleanup.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        let link = dataRoot.appendingPathComponent("style-link.png")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        let result = await h.runRaw("write_production_design", args: [
            "project_dir": dataRoot.path,
            "visual_medium": "2d_animation",
            "refs": [["path": "style-link.png", "note": "style"]],
            "color_script": [],
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("inside the project"))
        #expect(
            !FileManager.default.fileExists(
                atPath: dataRoot.appendingPathComponent(
                    "production_design/production_design.yaml"
                ).path
            )
        )
    }

    @Test("planning writers reject non-image reference files")
    func planningWriterRejectsNonImageReference() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let reference = dataRoot.appendingPathComponent(
            "production_design/refs/style.txt"
        )
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not an image".utf8).write(to: reference)

        let result = await h.runRaw("write_production_design", args: [
            "project_dir": dataRoot.path,
            "visual_medium": "2d_animation",
            "refs": [[
                "path": "production_design/refs/style.txt",
                "note": "style",
            ]],
            "color_script": [],
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("must name an image"))
        #expect(
            !FileManager.default.fileExists(
                atPath: dataRoot.appendingPathComponent(
                    "production_design/production_design.yaml"
                ).path
            )
        )
    }

    @Test("native shot source edits use the canonical pipeline data root")
    func nativeShotSourceEditUsesPipelineDataRoot() async throws {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "shot-source-root-\(UUID().uuidString)",
                isDirectory: true
            )
        let package = cleanup.appendingPathComponent(
            "Project.ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        _ = try ProjectScaffold.initProject(
            home: package,
            name: "demo",
            mode: .beat
        )

        let harness = ToolHarness()
        harness.editor.projectURL = package
        defer {
            harness.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let workingHome = try #require(harness.editor.workingRoot)
        let workingDataRoot = try #require(
            DataRootResolver.dataRoot(of: workingHome)
        )
        let initialInputs = try prepareNativeSourceExecution(
            dataRoot: workingDataRoot
        )
        let store = YAMLArtifactStore(dataRoot: workingDataRoot)
        var gates = try store.load(
            Gates.self,
            at: PipelineLayout.gatesFile
        )
        for phase in coreGatePhases.prefix(while: { $0 != "shotlist" }) {
            GatesOperations.approve(&gates, phase: phase)
        }
        try store.save(gates, to: PipelineLayout.gatesFile)
        let unchangedInput = initialInputs[1]

        let changed = await harness.editor.setShotSourceMode(
            shotId: "s001",
            to: .imported
        )

        #expect(changed)
        #expect(FileManager.default.fileExists(
            atPath: workingHome.appendingPathComponent(".ngv-dirty").path
        ))
        let shotlist = try #require(
            try loadShotlist(dataRoot: workingDataRoot)
        )
        #expect(shotlist.shots.first?.sourceMode == .imported)
        #expect(shotlist.shots.first?.productionPlan == nil)
        #expect(shotlist.shots.first?.sourcePath == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: workingHome.appendingPathComponent(
                    "shotlist",
                    isDirectory: true
                ).path
            )
        )
        #expect(latestShotlistVersion(dataRoot: workingDataRoot) == 2)
        try PipelineExecutionPlanWriter.requireCurrentShotlistBinding(
            dataRoot: workingDataRoot
        )
        let (executionPlan, context) = try PipelineExecutionPlanWriter.load(
            dataRoot: workingDataRoot
        )
        #expect(executionPlan.shots.map(\.sourceMode) == [.imported, .generated])
        #expect(context.artifacts.contains {
            $0.role == PipelineExecutionShotInputStore.artifactRole
                && $0.path == PipelineLayout.executionShotInputsFile
        })
        let storedInputs = try PipelineExecutionShotInputStore.loadCurrent(
            dataRoot: workingDataRoot
        ).executionShots
        #expect(storedInputs[0].sourceMode == .imported)
        #expect(storedInputs[1] == unchangedInput)
        let productionInputs = try PipelineProductionInputsWriter.load(
            shotID: "s002",
            dataRoot: workingDataRoot
        )
        #expect(productionInputs.1.shotID == "s002")
        #expect(productionInputs.2.shotID == "s002")
        #expect(!FileManager.default.fileExists(
            atPath: PipelineLayout.url(
                PipelineLayout.referenceDemandSetFile(shotID: "s001"),
                in: workingDataRoot
            ).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: PipelineLayout.url(
                PipelineLayout.productionInputTemplateFile(shotID: "s001"),
                in: workingDataRoot
            ).path
        ))

        let beforeFailure = try recursiveFileBytes(in: workingHome)
        let invalidEnhancement = await harness.editor.setShotSourceMode(
            shotId: "s001",
            to: .aiEnhanced
        )
        #expect(!invalidEnhancement)
        #expect(latestShotlistVersion(dataRoot: workingDataRoot) == 2)
        #expect(try recursiveFileBytes(in: workingHome) == beforeFailure)
    }

    @Test("native source edit preserves a successor's exact chain binding")
    func nativeShotSourceEditRejectsChainRetargeting() async throws {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "shot-source-chain-\(UUID().uuidString)",
                isDirectory: true
            )
        let package = cleanup.appendingPathComponent("Project.ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: package)
        let packageDataRoot = try ProjectScaffold.initProject(
            home: package,
            name: "demo",
            mode: .beat
        )
        _ = try prepareNativeSourceExecution(
            dataRoot: packageDataRoot,
            chainedSuccessor: true
        )

        let harness = ToolHarness()
        harness.editor.projectURL = package
        defer {
            harness.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let workingHome = try #require(harness.editor.workingRoot)
        let workingDataRoot = try #require(DataRootResolver.dataRoot(of: workingHome))
        let store = YAMLArtifactStore(dataRoot: workingDataRoot)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        for phase in coreGatePhases.prefix(while: { $0 != "shotlist" }) {
            GatesOperations.approve(&gates, phase: phase)
        }
        try store.save(gates, to: PipelineLayout.gatesFile)
        let before = try recursiveFileBytes(in: workingHome)

        let changed = await harness.editor.setShotSourceMode(
            shotId: "s001",
            to: .imported
        )

        #expect(!changed)
        #expect(try recursiveFileBytes(in: workingHome) == before)
        try PipelineExecutionPlanWriter.requireCurrentShotlistBinding(
            dataRoot: workingDataRoot
        )
        let shotlist = try #require(try loadShotlist(dataRoot: workingDataRoot))
        #expect(ChainContinuity.chainPredecessor(shotlist, shotId: "s002") == "s001")
    }

    @Test("shotlist writes fail closed when declared pack state is unreadable")
    func shotlistWriteRejectsUnreadablePackState() throws {
        let (_, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)
        let binding = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent(ProjectPluginSettings.filename)
        try Data("{broken".utf8).write(to: binding)

        #expect(throws: ToolError.self) {
            _ = try PipelineShotlistWriter.write(
                try minimalShotlist(),
                dataRoot: dataRoot,
                declaredPack: "musicvideo"
            )
        }
        #expect(latestShotlistVersion(dataRoot: dataRoot) == nil)
    }

    @Test("shotlist writer rejects a same-ID version change before writing")
    func shotlistWriteRejectsSameIDPackVersionChange() throws {
        let (_, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let trusted = try activatePack("musicvideo", dataRoot: dataRoot)
        let sibling = try #require(ProjectPackBinding(
            id: trusted.id,
            version: "0.4.5",
            projectSchema: trusted.projectSchema
        ))
        try ProjectPluginSettings.setActivePlugin(
            sibling,
            projectURL: FrameInventory.projectHome(of: dataRoot)
        )

        #expect(throws: ToolError.self) {
            _ = try PipelineShotlistWriter.write(
                try minimalShotlist(),
                dataRoot: dataRoot,
                declaredPack: trusted.id,
                declaredBinding: trusted
            )
        }
        #expect(latestShotlistVersion(dataRoot: dataRoot) == nil)
    }

    @Test("shotlist writes fail closed when the Brief is unreadable")
    func shotlistWriteRejectsUnreadableBrief() throws {
        let (_, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try Data("{broken".utf8).write(
            to: PipelineLayout.url(PipelineLayout.briefFile, in: dataRoot)
        )

        #expect(throws: ToolError.self) {
            _ = try PipelineShotlistWriter.write(
                try minimalShotlist(),
                dataRoot: dataRoot,
                declaredPack: nil
            )
        }
        #expect(latestShotlistVersion(dataRoot: dataRoot) == nil)
    }

    @Test("native shot source edits cannot bypass the current pipeline phase")
    func nativeShotSourceEditRequiresCurrentPhase() async throws {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "shot-source-phase-\(UUID().uuidString)",
                isDirectory: true
            )
        let package = cleanup.appendingPathComponent(
            "Project.ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let packageDataRoot = try ProjectScaffold.initProject(
            home: package,
            name: "demo",
            mode: .beat
        )
        try activatePack("musicvideo", dataRoot: packageDataRoot)
        _ = try saveShotlist(try minimalShotlist(), to: packageDataRoot)

        let harness = ToolHarness()
        harness.editor.projectURL = package
        defer {
            harness.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let workingDataRoot = try #require(
            harness.editor.workingRoot.flatMap {
                DataRootResolver.dataRoot(of: $0)
            }
        )

        let changed = await harness.editor.setShotSourceMode(
            shotId: "s001",
            to: .imported
        )

        #expect(!changed)
        #expect(latestShotlistVersion(dataRoot: workingDataRoot) == 1)
        let shotlist = try #require(
            try loadShotlist(dataRoot: workingDataRoot)
        )
        #expect(shotlist.shots.first?.sourceMode == .generated)
    }

    @Test("record_render then get_render_manifest / next_render_shot reflect the entry")
    func renderManifestRoundTrip() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(
            try minimalShotlist(keyframeStrategy: .none),
            to: dataRoot
        )
        let dir = dataRoot.path
        let video = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent("s001.mp4")
        try addGeneratedVideo(
            "s001-video",
            at: video,
            to: h,
            dataRoot: dataRoot
        )

        let recorded = try await h.runOK("record_render", args: [
            "project_dir": dir, "phase": "preview", "shot_id": "s001",
            "output": "s001-video", "cost_eur": 1.5,
        ]) as? [String: Any]
        #expect(recorded?["shot_id"] as? String == "s001")
        #expect(recorded?["status"] as? String == "rendered")
        #expect(recorded?["spent_eur"] as? Double == 1.5)

        let manifest = try await h.runOK("get_render_manifest", args: ["project_dir": dir, "phase": "preview"]) as? [String: Any]
        #expect(manifest?["phase"] as? String == "preview")
        let entries = try #require(manifest?["entries"] as? [String: Any])
        #expect(entries["s001"] != nil)
        let summary = try #require(manifest?["summary"] as? [String: Any])
        #expect(summary["total"] as? Int == 1)
        #expect(summary["rendered"] as? Int == 1)
        #expect(summary["spent_eur"] as? Double == 1.5)
        let proof = try loadRenderProofManifest(
            dataRoot: dataRoot,
            phase: "preview"
        )
        let entryProof = try #require(proof.entries["s001"])
        #expect(entryProof.output == "s001.mp4")
        #expect(entryProof.generationModel == "video-model")
        #expect(
            entryProof.providerPrompt
                == "Compiled provider prompt for s001-video."
        )
        #expect(entryProof.outputSha256 == (try FileDigest.sha256(of: video)))

        // s001 rendered → next_render_shot reports done.
        let next = try await h.runOK("next_render_shot", args: ["project_dir": dir, "phase": "preview"]) as? [String: Any]
        #expect(next?["done"] as? Bool == true)

        try Data("replaced-outside-the-render-path".utf8).write(to: video)
        let stale = await h.runRaw(
            "next_render_shot",
            args: ["project_dir": dir, "phase": "preview"]
        )
        #expect(stale.isError)
        #expect(
            ToolHarness.textOf(stale).contains("publication is unreadable")
                || ToolHarness.textOf(stale).contains("does not match")
        )
        let staleManifest = await h.runRaw(
            "get_render_manifest",
            args: ["project_dir": dir, "phase": "preview"]
        )
        #expect(staleManifest.isError)
    }

    @Test("record_render preserves the submitted asset provenance when URLs collide")
    func renderManifestUsesSubmittedAssetProvenance() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(
            try minimalShotlist(keyframeStrategy: .none),
            to: dataRoot
        )
        let video = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent("s001.mp4")
        try Data("current".utf8).write(to: video)
        h.editor.mediaAssets.append(
            MediaAsset(
                id: "stale-video",
                url: video,
                type: .video,
                name: "stale",
                generationInput: GenerationInput(
                    prompt: "Stale provider prompt.",
                    model: "stale-model",
                    duration: 4,
                    aspectRatio: "16:9"
                )
            )
        )
        try addGeneratedVideo(
            "current-video",
            at: video,
            to: h,
            dataRoot: dataRoot
        )

        _ = try await h.runOK("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "preview",
            "shot_id": "s001",
            "output": "current-video",
        ])

        let proof = try loadRenderProofManifest(
            dataRoot: dataRoot,
            phase: "preview"
        )
        #expect(
            proof.entries["s001"]?.providerPrompt
                == "Compiled provider prompt for current-video."
        )
        #expect(proof.entries["s001"]?.generationModel == "video-model")
    }

    @Test("record_render rejects media compiled for another shot")
    func renderManifestRejectsAnotherShotBinding() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(
            try minimalShotlist(keyframeStrategy: .none),
            to: dataRoot
        )
        let video = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent("wrong-shot.mp4")
        try addGeneratedVideo(
            "wrong-shot",
            at: video,
            to: h,
            dataRoot: dataRoot
        )
        let asset = try #require(
            h.editor.mediaAssets.first { $0.id == "wrong-shot" }
        )
        var input = try #require(asset.generationInput)
        input.promptShotId = "s999"
        asset.generationInput = input

        let result = await h.runRaw("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "preview",
            "shot_id": "s001",
            "output": "wrong-shot",
        ])

        #expect(result.isError)
        #expect(
            ToolHarness.textOf(result)
                .contains("was not compiled for shot 's001'")
        )
    }

    @Test("record_render rejects media compiled before the shot plan changed")
    func renderManifestRejectsStalePlanBinding() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let firstPlan = try ShotProductionPlan(
            primaryAction: "The performer crosses the doorway.",
            cameraMovement: .static,
            renderability: .green
        )
        _ = try saveShotlist(
            try minimalShotlist(
                keyframeStrategy: .none,
                productionPlan: firstPlan
            ),
            to: dataRoot
        )
        let video = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent("stale-plan.mp4")
        try addGeneratedVideo(
            "stale-plan",
            at: video,
            to: h,
            dataRoot: dataRoot
        )
        let revisedPlan = try ShotProductionPlan(
            primaryAction: "The performer stops inside the doorway.",
            cameraMovement: .dollyIn,
            renderability: .green
        )
        _ = try saveShotlist(
            try minimalShotlist(
                keyframeStrategy: .none,
                productionPlan: revisedPlan
            ),
            to: dataRoot
        )

        let result = await h.runRaw("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "preview",
            "shot_id": "s001",
            "output": "stale-plan",
        ])

        #expect(result.isError)
        #expect(
            ToolHarness.textOf(result)
                .contains("current shot production plan")
        )
    }

    @Test("next render shot hands a chained shot the predecessor's exact last frame")
    func nextRenderShotResolvesChainStart() async throws {
        let routing = falRoutingDependencies()
        let (h, dataRoot, cleanup) = try scaffold(
            providerActivation: { routing.activation },
            productionRouteCandidates: routing.candidates
        )
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try prepareNativeSourceExecution(
            dataRoot: dataRoot,
            chainedSuccessor: true
        )
        let home = FrameInventory.projectHome(of: dataRoot)
        let firstVideo = home.appendingPathComponent("s001.mp4")
        let lastFrame = home.appendingPathComponent("s001-last.png")
        let first = try await h.runOK(
            "next_render_shot",
            args: [
                "project_dir": dataRoot.path,
                "phase": "preview",
            ]
        ) as? [String: Any]
        #expect(first?["shot_id"] as? String == "s001")
        let firstRouting = try PipelineProductionRouting.requireCurrent(
            shotID: "s001",
            dataRoot: dataRoot,
            activation: routing.activation,
            candidateProvider: routing.candidates
        )
        try addGeneratedVideo(
            "s001-video",
            at: firstVideo,
            to: h,
            dataRoot: dataRoot,
            currentRouting: firstRouting
        )
        try addGeneratedImage("s001-last", at: lastFrame, to: h)
        let generationInput = try #require(
            h.editor.mediaAssets.first { $0.id == "s001-video" }?.generationInput
        )
        let generationRouting = try #require(generationInput.productionRouting)
        let outputSHA256 = try FileDigest.sha256(of: firstVideo)
        var manifest = RenderManifest(project: "demo", phase: "preview")
        record(
            &manifest,
            shotId: "s001",
            output: "s001.mp4",
            costEur: 1,
            phase: "preview",
            lastFramePath: "s001-last.png"
        )
        let proof = RenderProofManifest(
            project: "demo",
            phase: "preview",
            entries: [
                "s001": RenderProofEntry(
                    shotId: "s001",
                    output: "s001.mp4",
                    outputSha256: outputSHA256,
                    providerPrompt: generationInput.prompt,
                    generationModel: generationInput.model
                ),
            ]
        )
        let routingProof = PipelineRenderRoutingProofManifestV1(
            project: "demo",
            phase: "preview",
            entries: [
                "s001": PipelineRenderRoutingProofEntryV1(
                    shotID: "s001",
                    output: "s001.mp4",
                    outputSHA256: outputSHA256,
                    generation: generationRouting
                ),
            ]
        )
        let lastFrameData = try Data(contentsOf: lastFrame)
        let lastFrameProof = RenderLastFrameProofV1(
            shotID: "s001",
            phase: "preview",
            path: "s001-last.png",
            sha256: FileDigest.sha256(of: lastFrameData),
            sourceOutput: "s001.mp4",
            sourceOutputSHA256: outputSHA256,
            extractedAt: "2026-08-31T00:00:00+00:00"
        )
        _ = try PipelineRenderRecordWriter.publish(
            manifest: manifest,
            proof: proof,
            routingProof: routingProof,
            framesManifest: nil,
            replacingShotID: "s001",
            preparedLastFrame: .init(
                proof: lastFrameProof,
                data: lastFrameData
            ),
            expectedPublicationTransactionID: nil,
            dataRoot: dataRoot
        )

        let next = try await h.runOK(
            "next_render_shot",
            args: [
                "project_dir": dataRoot.path,
                "phase": "preview",
            ]
        ) as? [String: Any]

        #expect(next?["shot_id"] as? String == "s002")
        #expect(next?["chain_with_previous_end"] as? Bool == true)
        #expect(
            next?["chain_start_frame_media_ref"] as? String
                == "s001-last"
        )
        #expect(
            next?["chain_start_frame_path"] as? String
                == "s001-last.png"
        )
    }

    @Test("get_frames_manifest exposes role-aware prompt and exact-file audit state")
    func framesManifestReadSurface() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let image = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent("s001.png")
        try Data("frame-v1".utf8).write(to: image)
        try saveFramesManifest(
            FramesManifest(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                shots: [
                    ShotFrames(
                        shotId: "s001",
                        keyframeStrategy: "start",
                        frames: [
                            FrameEntry(
                                role: "start",
                                path: "s001.png",
                                runwayModel: "image-model",
                                providerPrompt: "Compiled provider prompt"
                            ),
                        ]
                    ),
                ]
            ),
            dataRoot: dataRoot
        )
        let digest = SHA256.hash(data: try Data(contentsOf: image))
            .map { String(format: "%02x", $0) }
            .joined()
        let checks = Dictionary(uniqueKeysWithValues: standardAuditCheckKeys.map {
            ($0, AuditCheck(status: .clean))
        })
        try saveFrameAudit(
            try FrameAudit(
                shotId: "s001",
                renderPath: "s001.png",
                renderSha256: digest,
                generated: "2026-07-26T00:00:00Z",
                auditor: "test",
                checks: checks,
                overall: .clean
            ),
            dataRoot: dataRoot
        )

        let current = try #require(
            try await h.runOK(
                "get_frames_manifest",
                args: ["project_dir": dataRoot.path]
            ) as? [String: Any]
        )
        let shots = try #require(current["shots"] as? [[String: Any]])
        let frames = try #require(shots.first?["frames"] as? [[String: Any]])
        #expect(frames.first?["provider_prompt"] as? String == "Compiled provider prompt")
        let audit = try #require(frames.first?["audit"] as? [String: Any])
        #expect(audit["current_image"] as? Bool == true)

        try Data("frame-v2".utf8).write(to: image)
        let stale = try #require(
            try await h.runOK(
                "get_frames_manifest",
                args: ["project_dir": dataRoot.path]
            ) as? [String: Any]
        )
        let staleShots = try #require(stale["shots"] as? [[String: Any]])
        let staleFrames = try #require(staleShots.first?["frames"] as? [[String: Any]])
        let staleAudit = try #require(staleFrames.first?["audit"] as? [String: Any])
        #expect(staleAudit["current_image"] as? Bool == false)
    }

    @Test("Frames queue requires and records every start_end role")
    func framesQueueIsRoleAware() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let shot = try Shot(
            id: "s001",
            section: "verse",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .performance,
            description: "d",
            visualPrompt: "p",
            mood: "m",
            keyframeStrategy: .startEnd
        )
        let song = try Song(
            title: "t",
            audioPath: "a.wav",
            analysisPath: "an.json",
            bpm: 120,
            durationS: 4
        )
        _ = try saveShotlist(
            try Shotlist(
                schema_: shotlistSchemaVersion,
                mode: .section,
                project: "demo",
                song: song,
                generated: "2026-07-26",
                generator: "test",
                shots: [shot]
            ),
            to: dataRoot
        )

        let first = try #require(
            try await h.runOK(
                "next_render_shot",
                args: ["project_dir": dataRoot.path, "phase": "frames"]
            ) as? [String: Any]
        )
        #expect(first["shot_id"] as? String == "s001")
        #expect(first["role"] as? String == "start")

        let home = FrameInventory.projectHome(of: dataRoot)
        func addGeneratedFrame(_ id: String) throws {
            let url = home.appendingPathComponent("\(id).png")
            try Data(id.utf8).write(to: url)
            var input = GenerationInput(
                prompt: "Compiled \(id)",
                model: "image-model",
                duration: 0,
                aspectRatio: "16:9"
            )
            input.intent = "Frame \(id)"
            input.promptShotId = "s001"
            input.promptProjectKey = dataRoot.standardizedFileURL
                .resolvingSymlinksInPath().path
            input.promptShotFingerprint = try PromptCompiler.shotFingerprint(shot)
            h.editor.mediaAssets.append(
                MediaAsset(
                    id: id,
                    url: url,
                    type: .image,
                    name: id,
                    generationInput: input
                )
            )
        }

        try addGeneratedFrame("start-frame")
        _ = try await h.runOK("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "frames",
            "shot_id": "s001",
            "role": "start",
            "output": "start-frame",
        ])
        let second = try #require(
            try await h.runOK(
                "next_render_shot",
                args: ["project_dir": dataRoot.path, "phase": "frames"]
            ) as? [String: Any]
        )
        #expect(second["shot_id"] as? String == "s001")
        #expect(second["role"] as? String == "end")

        try addGeneratedFrame("end-frame")
        _ = try await h.runOK("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "frames",
            "shot_id": "s001",
            "role": "end",
            "output": "end-frame",
        ])
        let done = try #require(
            try await h.runOK(
                "next_render_shot",
                args: ["project_dir": dataRoot.path, "phase": "frames"]
            ) as? [String: Any]
        )
        #expect(done["done"] as? Bool == true)
        let manifest = try loadFramesManifest(dataRoot: dataRoot)
        #expect(Set(manifest.shot("s001")?.frames.map(\.role) ?? []) == ["start", "end"])
    }

    @Test("Frames recording rejects images without generation provenance")
    func framesRecordRequiresGenerationProvenance() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)
        let image = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent("manual.png")
        try Data("manual".utf8).write(to: image)
        h.editor.mediaAssets.append(
            MediaAsset(
                id: "manual-image",
                url: image,
                type: .image,
                name: "manual"
            )
        )

        let result = await h.runRaw("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "frames",
            "shot_id": "s001",
            "role": "start",
            "output": "manual.png",
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("no generation provenance"))
        let framesURL = PipelineLayout.url(
            PipelineLayout.framesManifestFile,
            in: dataRoot
        )
        #expect(!FileManager.default.fileExists(atPath: framesURL.path))
    }

    @Test("video recording rejects files without generation provenance")
    func videoRecordRequiresGenerationProvenance() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)
        let video = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent("manual.mp4")
        try Data("manual".utf8).write(to: video)
        h.editor.mediaAssets.append(
            MediaAsset(
                id: "manual-video",
                url: video,
                type: .video,
                name: "manual"
            )
        )

        let result = await h.runRaw("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "final",
            "shot_id": "s001",
            "output": "manual.mp4",
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("no generation provenance"))
        let manifest = try loadRenderManifest(
            dataRoot: dataRoot,
            phase: "final"
        )
        #expect(manifest.entries.isEmpty)
    }

    @Test("record_render rejects media that is still rendering")
    func recordRenderRequiresCompletedMedia() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(
            try minimalShotlist(keyframeStrategy: .none),
            to: dataRoot
        )
        let video = FrameInventory.projectHome(of: dataRoot)
            .appendingPathComponent("s001.mp4")
        try addGeneratedVideo(
            "s001-video",
            at: video,
            to: h,
            dataRoot: dataRoot
        )
        let asset = try #require(
            h.editor.mediaAssets.first { $0.id == "s001-video" }
        )
        asset.generationStatus = .rendering

        let result = await h.runRaw("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "preview",
            "shot_id": "s001",
            "output": "s001-video",
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not completed media"))
        let manifest = try loadRenderManifest(
            dataRoot: dataRoot,
            phase: "preview"
        )
        #expect(manifest.entries.isEmpty)
    }

    @Test("render tools refuse and preserve a corrupt manifest")
    func corruptRenderManifestIsNotOverwritten() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)
        let manifestURL = PipelineLayout.url(
            PipelineLayout.renderManifestFile(phase: "preview"),
            in: dataRoot
        )
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corrupt = Data("{\"entries\":".utf8)
        try corrupt.write(to: manifestURL)
        try Data("render".utf8).write(
            to: FrameInventory.projectHome(of: dataRoot)
                .appendingPathComponent("s001.mp4")
        )

        let next = await h.runRaw("next_render_shot", args: [
            "project_dir": dataRoot.path,
            "phase": "preview",
        ])
        let record = await h.runRaw("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "preview",
            "shot_id": "s001",
            "output": "s001.mp4",
        ])

        #expect(next.isError)
        #expect(record.isError)
        #expect(try Data(contentsOf: manifestURL) == corrupt)
    }

    @Test("next_render_shot surfaces the first unrendered shot's prompt")
    func nextRenderShotPending() async throws {
        let routing = falRoutingDependencies()
        let (h, dataRoot, cleanup) = try scaffold(
            providerActivation: { routing.activation },
            productionRouteCandidates: routing.candidates
        )
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let plan = try ShotProductionPlan(
            primaryAction: "performer turns toward camera",
            cameraMovement: .static,
            narrativeBeat: .performance,
            renderability: .yellow,
            risks: [.identityDrift],
            rescueCut: "Cut to a profile reaction",
            continuityLocks: ["silver jacket"]
        )
        _ = try publishExecutionShotlist(
            try minimalShotlist(
                keyframeStrategy: .none,
                productionPlan: plan
            ),
            dataRoot: dataRoot
        )
        let next = try await h.runOK("next_render_shot", args: ["project_dir": dataRoot.path, "phase": "preview"]) as? [String: Any]
        #expect(next?["done"] as? Bool == false)
        #expect(next?["shot_id"] as? String == "s001")
        #expect(next?["visual_prompt"] as? String == "p")
        #expect(next?["source_mode"] as? String == "generated")
        let renderedPlan = next?["production_plan"] as? [String: Any]
        #expect(renderedPlan?["primary_action"] as? String == "performer turns toward camera")
        #expect(renderedPlan?["camera_movement"] as? String == "static")
        #expect(renderedPlan?["rescue_cut"] as? String == "Cut to a profile reaction")
    }

    /// A 3-shot shotlist: s001 imported, s002 generated, s003 ai_enhanced.
    private func hybridShotlist() throws -> Shotlist {
        func shot(_ id: String, _ start: Double, _ mode: SourceMode) throws -> Shot {
            let productionPlan = mode == .imported
                ? nil
                : try ShotProductionPlan(
                    primaryAction: "Hold the composition.",
                    cameraMovement: .static,
                    renderability: .green
                )
            return try Shot(
                id: id, section: "verse", timeStart: start, timeEnd: start + 4.0, durationS: 4.0,
                type: .performance, sourceMode: mode, description: "d",
                visualPrompt: "p", mood: "m", keyframeStrategy: .none,
                sourcePath: mode == .aiEnhanced
                    ? "media/s003-source.mp4"
                    : nil,
                productionPlan: productionPlan
            )
        }
        let song = try Song(title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: 12.0)
        return try Shotlist(
            schema_: shotlistSchemaVersion, mode: .section, project: "demo", song: song,
            generated: "2026-01-01", generator: "test",
            shots: [
                try shot("s001", 0.0, .imported),
                try shot("s002", 4.0, .generated),
                try shot("s003", 8.0, .aiEnhanced),
            ]
        )
    }

    @Test("next_render_shot skips imported shots and returns ai_enhanced with its source_mode")
    func nextRenderShotSkipsLiveAction() async throws {
        let routing = hybridRoutingDependencies()
        let (h, dataRoot, cleanup) = try scaffold(
            providerActivation: { routing.activation },
            productionRouteCandidates: routing.candidates
        )
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let dir = dataRoot.path
        let home = FrameInventory.projectHome(of: dataRoot)
        try addSourceVideo(
            "s003-source",
            at: home.appendingPathComponent("media/s003-source.mp4"),
            to: h
        )
        _ = try publishExecutionShotlist(
            try hybridShotlist(),
            dataRoot: dataRoot
        )
        // s001 is imported → skipped; the first render shot is the generated s002.
        let first = try await h.runOK("next_render_shot", args: ["project_dir": dir, "phase": "preview"]) as? [String: Any]
        #expect(first?["shot_id"] as? String == "s002")
        #expect(first?["source_mode"] as? String == "generated")
        let firstRouting = try PipelineProductionRouting.requireCurrent(
            shotID: "s002",
            dataRoot: dataRoot,
            activation: routing.activation,
            candidateProvider: routing.candidates
        )
        try addGeneratedVideo(
            "s002-video",
            at: home.appendingPathComponent("s002.mp4"),
            to: h,
            dataRoot: dataRoot,
            shotId: "s002",
            currentRouting: firstRouting
        )

        // Record s002 → the enhanced s003 is next (enhanced shots ARE queued).
        _ = try await h.runOK("record_render", args: [
            "project_dir": dir, "phase": "preview", "shot_id": "s002",
            "output": "s002-video", "cost_eur": 1.0,
        ])
        let second = try await h.runOK("next_render_shot", args: ["project_dir": dir, "phase": "preview"]) as? [String: Any]
        #expect(second?["shot_id"] as? String == "s003")
        #expect(second?["source_mode"] as? String == "ai_enhanced")
        #expect(second?["source_video_media_ref"] as? String == "s003-source")
        #expect(second?["source_video_path"] as? String == "media/s003-source.mp4")
        let currentRouting = try PipelineProductionRouting.requireCurrent(
            shotID: "s003",
            dataRoot: dataRoot,
            activation: routing.activation,
            candidateProvider: routing.candidates
        )
        try addGeneratedVideo(
            "s003-video",
            at: home.appendingPathComponent("s003.mp4"),
            to: h,
            dataRoot: dataRoot,
            shotId: "s003",
            currentRouting: currentRouting
        )

        // Record s003 → done. s001 (imported) never appears, so the queue is empty.
        _ = try await h.runOK("record_render", args: [
            "project_dir": dir, "phase": "preview", "shot_id": "s003",
            "output": "s003-video", "cost_eur": 1.0,
        ])
        let done = try await h.runOK("next_render_shot", args: ["project_dir": dir, "phase": "preview"]) as? [String: Any]
        #expect(done?["done"] as? Bool == true)
    }

    @Test("next_render_shot rejects an AI-enhanced source that escapes through a symlink")
    func nextRenderShotRejectsEnhancedSourceSymlinkEscape() async throws {
        let routing = falRoutingDependencies()
        let (h, dataRoot, cleanup) = try scaffold(
            providerActivation: { routing.activation },
            productionRouteCandidates: routing.candidates
        )
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = FrameInventory.projectHome(of: dataRoot)
        let outside = cleanup.appendingPathComponent("outside.mp4")
        try Data("outside".utf8).write(to: outside)
        let source = home.appendingPathComponent("media/s003-source.mp4")
        try addSourceVideo(
            "s003-source",
            at: source,
            to: h
        )
        _ = try publishExecutionShotlist(
            try hybridShotlist(),
            dataRoot: dataRoot
        )
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(
            at: source,
            withDestinationURL: outside
        )
        try addGeneratedVideo(
            "s002-video",
            at: home.appendingPathComponent("s002.mp4"),
            to: h,
            dataRoot: dataRoot,
            shotId: "s002"
        )
        _ = try await h.runOK("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "preview",
            "shot_id": "s002",
            "output": "s002-video",
        ])

        let result = await h.runRaw("next_render_shot", args: [
            "project_dir": dataRoot.path,
            "phase": "preview",
        ])

        #expect(result.isError)
        #expect(
            ToolHarness.textOf(result).contains(
                "no current project-local source video"
            )
        )
    }

    @Test("write_shotlist rejects AI-enhanced shots without a durable source")
    func shotlistWriterRequiresEnhancedSource() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try YAMLArtifactStore(dataRoot: dataRoot).save(
            try Brief(
                project: "demo",
                generated: "2026-07-26T00:00:00Z",
                mission: .demo,
                targetPlatform: "YouTube",
                aspectRatio: .landscape16x9,
                projectMode: "section",
                budgetEur: 50,
                conceptType: .narrative,
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                tone: [.quiet],
                figures: .none,
                lyricsIntegration: .metaphorical
            ),
            to: PipelineLayout.briefFile
        )
        _ = try writeMeasuredAnalysis(dataRoot: dataRoot)
        let shot: [String: Any] = [
            "id": "s001",
            "section": "verse",
            "time_start": 0,
            "time_end": 12,
            "duration_s": 12,
            "type": "performance",
            "source_mode": "ai_enhanced",
            "description": "Enhance the imported performance.",
            "visual_prompt": "Preserve the performance and restyle the surface.",
            "mood": "restrained",
            "character_refs": [],
            "character_views": [],
            "keyframe_strategy": "none",
            "visible_zones": [],
            "zone_introduces": [],
            "character_blocking": [],
            "prop_refs": [],
            "prop_views": [],
            "redo": false,
            "scene_video_provider": "runway",
            "seedance_input_mode": "keyframe",
            "reference_image_refs": [],
            "chain_with_previous_end": false,
            "transition_in": "hard_cut",
            "transition_out": "hard_cut",
            "production_plan": [
                "primary_action": "Restyle the imported performance.",
                "camera_movement": "static",
                "narrative_beat": "action",
                "renderability": "green",
                "risks": [],
                "continuity_locks": [],
                "blocking_anchors": [],
            ],
        ]

        let result = await h.runRaw("write_shotlist", args: [
            "project_dir": dataRoot.path,
            "shots": [shot],
            "execution_shots": [generatedExecutionShotInput(firstFrame: false)],
        ])

        #expect(result.isError)
        #expect(
            ToolHarness.textOf(result).contains(
                "source_path"
            )
        )
        #expect(try loadShotlist(dataRoot: dataRoot) == nil)
    }

    @Test("record_render never admits imported shots into a provider manifest")
    func renderManifestRejectsImportedShots() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try hybridShotlist(), to: dataRoot)

        let result = await h.runRaw("record_render", args: [
            "project_dir": dataRoot.path,
            "phase": "final",
            "shot_id": "s001",
            "status": "failed",
        ])

        #expect(result.isError)
        #expect(
            ToolHarness.textOf(result).contains(
                "does not belong in a provider render manifest"
            )
        )
        #expect(
            (try loadRenderManifest(
                dataRoot: dataRoot,
                phase: "final"
            )).entries.isEmpty
        )
    }

    @Test("get_bible returns null on a fresh project")
    func bibleNull() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let result = await h.runRaw("get_bible", args: ["project_dir": dataRoot.path])
        #expect(result.isError == false)
        #expect(ToolHarness.textOf(result).trimmingCharacters(in: .whitespacesAndNewlines) == "null")
    }

    @Test("run_phase reports the agent-driven no-runner shape for a planning phase")
    func runPhaseNoRunner() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let result = try await h.runOK("run_phase", args: ["project_dir": dataRoot.path, "phase": "brief"]) as? [String: Any]
        #expect(result?["phase"] as? String == "brief")
        #expect(result?["runner"] is NSNull)
        #expect((result?["note"] as? String)?.contains("agent-driven") == true)
    }

    @Test("write_analysis_interpretation preserves measurements and detector anomalies")
    func writeAnalysisInterpretation() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)
        let analysisURL = try writeMeasuredAnalysis(dataRoot: dataRoot)

        let result = try await h.runOK(
            "write_analysis_interpretation",
            args: [
                "project_dir": dataRoot.path,
                "tempo_multiplier": 0.5,
                "section_labels": [
                    [
                        "index": 0,
                        "label": "intro",
                        "confidence": 0.8,
                        "note": "low-energy opening",
                    ],
                    [
                        "index": 1,
                        "label": "chorus1",
                        "confidence": 0.9,
                    ],
                ],
                "anomalies": [[
                    "kind": "low_label_confidence",
                    "time": 4.0,
                    "detail": "No lyrics were supplied.",
                ]],
                "overall_character": "Half-time pulse with a restrained opening and a broad release.",
            ]
        ) as? [String: Any]
        #expect(result?["tempo_multiplier"] as? Double == 0.5)
        #expect(result?["perceived_bpm"] as? Double == 60)

        let persisted = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: analysisURL)
            ) as? [String: Any]
        )
        #expect(persisted["bpm"] as? Double == 120)
        let sections = try #require(persisted["sections"] as? [[String: Any]])
        #expect(sections[0]["start"] as? Double == 0)
        #expect(sections[0]["end"] as? Double == 4)
        #expect(sections[0]["label"] as? String == "intro")
        #expect(sections[0]["confidence"] as? Double == 0.95)
        #expect(sections[1]["label"] as? String == "chorus1")
        #expect(sections[1]["confidence"] as? Double == 0.95)
        let interpretation = try #require(
            persisted["interpretation"] as? [String: Any]
        )
        let labels = try #require(
            interpretation["section_labels"] as? [[String: Any]]
        )
        #expect(labels[0]["confidence"] as? String == "0.800")
        let anomalies = try #require(
            interpretation["anomalies"] as? [[String: Any]]
        )
        #expect(anomalies.contains {
            $0["kind"] as? String == "boundary_divergence"
        })
        #expect(anomalies.contains {
            $0["kind"] as? String == "low_label_confidence"
        })
        let encoded = try Data(contentsOf: analysisURL)
        #expect(encoded.last == 0x0A)
        #expect(String(decoding: encoded, as: UTF8.self).contains("audio/song.wav"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains(#"audio\/song.wav"#))
    }

    @Test("write_analysis_interpretation requires the exact measured alignment source")
    func writeAnalysisInterpretationRejectsMissingAlignmentSource() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)
        _ = try writeMeasuredAnalysis(dataRoot: dataRoot)
        try FileManager.default.removeItem(
            at: dataRoot.appendingPathComponent("analysis/stems/vocals.wav")
        )

        let result = await h.runRaw(
            "write_analysis_interpretation",
            args: [
                "project_dir": dataRoot.path,
                "tempo_multiplier": 1.0,
                "section_labels": [
                    ["index": 0, "label": "intro", "confidence": 1.0],
                    ["index": 1, "label": "verse", "confidence": 1.0],
                ],
                "anomalies": [],
                "overall_character": "Measured structure.",
            ]
        )

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("measured alignment source is missing"))
    }

    @Test("write_analysis_interpretation rejects an unresolved structure")
    func writeAnalysisInterpretationRejectsUnresolvedFixture() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)
        _ = try writeUnresolvedAnalysis(dataRoot: dataRoot)

        let result = await h.runRaw(
            "write_analysis_interpretation",
            args: [
                "project_dir": dataRoot.path,
                "tempo_multiplier": 1.0,
                "section_labels": [[
                    "index": 0,
                    "label": "full track",
                    "confidence": 0.6,
                ]],
                "anomalies": [],
                "overall_character": "One measured span awaiting explicit review.",
            ]
        )

        #expect(result.isError)
    }

    @Test("write_analysis_interpretation cannot hide unresolved section timing")
    func writeAnalysisInterpretationRejectsUnresolvedStructure() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)
        let analysisURL = try writeMeasuredAnalysis(dataRoot: dataRoot)
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: analysisURL)) as? [String: Any]
        )
        var resolution = try #require(object["structure_resolution"] as? [String: Any])
        resolution["status"] = "needs_review"
        resolution["method"] = "unresolved"
        object["structure_resolution"] = resolution
        try JSONSerialization.data(withJSONObject: object).write(to: analysisURL)
        try recordAnalysisLineage(dataRoot: dataRoot)
        let before = try Data(contentsOf: analysisURL)

        let result = await h.runRaw(
            "write_analysis_interpretation",
            args: [
                "project_dir": dataRoot.path,
                "tempo_multiplier": 1.0,
                "section_labels": [
                    ["index": 0, "label": "intro", "confidence": 0.8],
                    ["index": 1, "label": "verse", "confidence": 0.8],
                ],
                "anomalies": [],
                "overall_character": "Must not be written.",
            ]
        )

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("native structure remains unresolved"))
        #expect(try Data(contentsOf: analysisURL) == before)
    }

    @Test("write_analysis_interpretation rejects incomplete coverage without changing analysis")
    func writeAnalysisInterpretationRejectsPartialCoverage() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)
        let analysisURL = try writeMeasuredAnalysis(dataRoot: dataRoot)
        let before = try Data(contentsOf: analysisURL)

        let result = await h.runRaw(
            "write_analysis_interpretation",
            args: [
                "project_dir": dataRoot.path,
                "tempo_multiplier": 1.0,
                "section_labels": [[
                    "index": 0,
                    "label": "intro",
                    "confidence": 0.8,
                ]],
                "anomalies": [],
                "overall_character": "Incomplete on purpose.",
            ]
        )

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("exactly one entry"))
        #expect(try Data(contentsOf: analysisURL) == before)
    }

    @Test("write_analysis_interpretation rejects analysis for replaced track without changing it")
    func writeAnalysisInterpretationRejectsReplacedTrack() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)
        let analysisURL = try writeMeasuredAnalysis(dataRoot: dataRoot)
        let before = try Data(contentsOf: analysisURL)
        try Data("replacement".utf8).write(
            to: dataRoot.appendingPathComponent("audio/song.wav"),
            options: .atomic
        )

        let result = await h.runRaw(
            "write_analysis_interpretation",
            args: [
                "project_dir": dataRoot.path,
                "tempo_multiplier": 1.0,
                "section_labels": [
                    [
                        "index": 0,
                        "label": "intro",
                        "confidence": 0.8,
                    ],
                    [
                        "index": 1,
                        "label": "chorus",
                        "confidence": 0.9,
                    ],
                ],
                "anomalies": [],
                "overall_character": "Should never be persisted.",
            ]
        )

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("current project track"))
        #expect(try Data(contentsOf: analysisURL) == before)
    }

    @Test("write_analysis_interpretation fails closed when the active pack is unavailable")
    func writeAnalysisInterpretationRejectsUnavailablePack() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let analysisURL = try writeMeasuredAnalysis(dataRoot: dataRoot)
        let before = try Data(contentsOf: analysisURL)
        try ProjectPluginSettings.setActivePlugin(
            "unavailable-pack",
            projectURL: FrameInventory.projectHome(of: dataRoot)
        )

        let result = await h.runRaw(
            "write_analysis_interpretation",
            args: [
                "project_dir": dataRoot.path,
                "tempo_multiplier": 1.0,
                "section_labels": [
                    ["index": 0, "label": "intro", "confidence": 0.8],
                    ["index": 1, "label": "verse", "confidence": 0.8],
                ],
                "anomalies": [],
                "overall_character": "Must not be written.",
            ]
        )

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not pinned to an exact version"))
        #expect(try Data(contentsOf: analysisURL) == before)
    }

    @Test("run_phase reaches the active pack's engine-pinned analysis machinery (resolved from home)")
    func runPhaseReachesPackRunner() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)

        // With the pack active but no song in audio/, the pack's engine-pinned one_song_contract step
        // (#174) fires and blocks analysis upfront with its actionable message — proving the pack
        // resolved (only a wired pack registers that step), NOT the "no code runner" shape the pre-fix
        // nil-pack resolution gave.
        let result = await h.runRaw(
            "run_phase",
            args: ["project_dir": dataRoot.path, "phase": "analysis"]
        )
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("one_song_contract"))
        #expect(ToolHarness.textOf(result).contains("audio/"))
    }

    @Test("run_phase rejects a mismatched exact pack before deterministic work")
    func runPhaseRejectsMismatchedPackVersion() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let trusted = try activatePack("musicvideo", dataRoot: dataRoot)
        let sibling = try #require(ProjectPackBinding(
            id: trusted.id,
            version: "0.4.5",
            projectSchema: trusted.projectSchema
        ))
        try ProjectPluginSettings.setActivePlugin(
            sibling,
            projectURL: FrameInventory.projectHome(of: dataRoot)
        )

        let result = await h.runRaw(
            "run_phase",
            args: ["project_dir": dataRoot.path, "phase": "analysis"]
        )
        #expect(result.isError)
        #expect(!ToolHarness.textOf(result).contains("one_song_contract"))
    }

    // MARK: - attach_song

    private func writeStub(_ url: URL, frequency: Double = 440) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard AudioProjectLayout.audioExtensions.contains(
            url.pathExtension.lowercased()
        ) else {
            try Data("not-audio".utf8).write(to: url)
            return
        }
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                channels: 1,
                interleaved: false
            )
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let frames: AVAudioFrameCount = 4_410
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(
                0.25 * sin(2 * Double.pi * frequency * Double(index) / 44_100)
            )
        }
        try file.write(from: buffer)
    }

    @Test("attach_song copies an absolute-path song into audio/ and returns filename + audio_dir")
    func attachSongFromPath() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let song = cleanup.appendingPathComponent("song.wav")
        try writeStub(song)

        let out = try #require(try await h.runOK("attach_song", args: [
            "project_dir": dataRoot.path, "path": song.path,
        ]) as? [String: Any])
        #expect(out["filename"] as? String == "song.wav")
        let audioDir = try #require(out["audio_dir"] as? String)
        let copied = URL(fileURLWithPath: audioDir).appendingPathComponent("song.wav")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        // The original is untouched (a copy, not a move).
        #expect(FileManager.default.fileExists(atPath: song.path))
        let anchorRef = try #require(out["asset_id"] as? String)
        let anchorId = try #require(
            h.editor.mediaAssets.first { $0.id.hasPrefix(anchorRef) }?.id
        )
        #expect(h.editor.mediaManifest.songAnchorAssetId == anchorId)
        #expect(h.editor.mediaManifest.intakeRoleByAssetID[anchorId] == "song")

        let repeated = try #require(try await h.runOK("attach_song", args: [
            "project_dir": dataRoot.path, "path": song.path,
        ]) as? [String: Any])
        #expect(repeated["asset_id"] as? String == anchorRef)
        let anchorClips = h.editor.timeline.tracks
            .filter { $0.type == .audio }
            .flatMap(\.clips)
            .filter { $0.mediaRef == anchorId }
        #expect(anchorClips.count == 1)
        #expect(anchorClips.first?.startFrame == 0)

    }

    @Test("attach_song copies a media-library asset's file into audio/")
    func attachSongFromMedia() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let hash = String(repeating: "4", count: 64)
        let song = cleanup.appendingPathComponent("\(hash).wav")
        try writeStub(song)
        let asset = MediaAsset(
            id: UUID().uuidString,
            url: song,
            type: .audio,
            name: "Claude Mouse",
            originalFilename: "Claude Mouse.wav"
        )
        h.editor.mediaAssets.append(asset)

        // Pass an id prefix — expandingIdPrefixes must resolve it, then the file is copied in.
        let ref = String(asset.id.prefix(8))
        let out = try #require(try await h.runOK("attach_song", args: [
            "project_dir": dataRoot.path, "media": ref,
        ]) as? [String: Any])
        #expect(out["filename"] as? String == "Claude Mouse.wav")
        let audioDir = try #require(out["audio_dir"] as? String)
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: audioDir)
                .appendingPathComponent("Claude Mouse.wav").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: audioDir)
                .appendingPathComponent("\(hash).wav").path
        ) == false)
    }

    @Test("attach_song reconstructs a readable filename for a legacy library asset")
    func attachSongFromLegacyMedia() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let hash = String(repeating: "8", count: 64)
        let song = cleanup.appendingPathComponent("\(hash).wav")
        try writeStub(song)
        let asset = MediaAsset(
            id: UUID().uuidString,
            url: song,
            type: .audio,
            name: "Claude Mouse"
        )
        h.editor.mediaAssets.append(asset)

        let out = try #require(try await h.runOK("attach_song", args: [
            "project_dir": dataRoot.path,
            "media": String(asset.id.prefix(8)),
        ]) as? [String: Any])

        #expect(out["filename"] as? String == "Claude Mouse.wav")
        let audioDir = URL(fileURLWithPath: try #require(out["audio_dir"] as? String))
        #expect(FileManager.default.fileExists(
            atPath: audioDir.appendingPathComponent("Claude Mouse.wav").path
        ))
    }

    @Test("attach_song rejects a non-audio source")
    func attachSongRejectsNonAudio() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let notAudio = cleanup.appendingPathComponent("frame.png")
        try writeStub(notAudio)
        let result = await h.runRaw("attach_song", args: ["project_dir": dataRoot.path, "path": notAudio.path])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("audio type"))
    }

    @Test("attach_song refuses a different existing song without replace, then swaps it with replace")
    func attachSongReplace() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let first = cleanup.appendingPathComponent("first.wav")
        let second = cleanup.appendingPathComponent("second.wav")
        try writeStub(first, frequency: 220)
        try writeStub(second, frequency: 880)

        let firstResult = try #require(try await h.runOK(
            "attach_song",
            args: ["project_dir": dataRoot.path, "path": first.path]
        ) as? [String: Any])
        let firstRef = try #require(firstResult["asset_id"] as? String)
        let firstId = try #require(
            h.editor.mediaAssets.first { $0.id.hasPrefix(firstRef) }?.id
        )

        // A different song without replace → actionable error naming the existing one.
        let refused = await h.runRaw("attach_song", args: ["project_dir": dataRoot.path, "path": second.path])
        #expect(refused.isError)
        #expect(ToolHarness.textOf(refused).contains("first.wav"))

        // replace: true swaps — first.wav is gone, second.wav is the only song.
        let swapped = try #require(try await h.runOK("attach_song", args: [
            "project_dir": dataRoot.path, "path": second.path, "replace": true,
        ]) as? [String: Any])
        let audioDir = URL(fileURLWithPath: try #require(swapped["audio_dir"] as? String))
        #expect(FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("second.wav").path))
        #expect(FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("first.wav").path) == false)
        let secondRef = try #require(swapped["asset_id"] as? String)
        let secondId = try #require(
            h.editor.mediaAssets.first { $0.id.hasPrefix(secondRef) }?.id
        )
        #expect(secondRef != firstRef)
        #expect(h.editor.mediaManifest.songAnchorAssetId == secondId)
        #expect(h.editor.mediaManifest.intakeRoleByAssetID[secondId] == "song")
        #expect(h.editor.mediaManifest.intakeRoleByAssetID[firstId] == nil)
        #expect(h.editor.mediaAssets.contains { $0.id == firstId } == false)
        let audioClips = h.editor.timeline.tracks
            .filter { $0.type == .audio }
            .flatMap(\.clips)
        #expect(audioClips.filter { $0.mediaRef == firstId }.isEmpty)
        #expect(audioClips.filter { $0.mediaRef == secondId && $0.startFrame == 0 }.count == 1)
    }

    @Test("attach_song preserves the current song when replacement staging fails")
    func attachSongFailedReplacementPreservesCurrentSong() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let first = cleanup.appendingPathComponent("first.wav")
        let second = cleanup.appendingPathComponent("second.wav")
        try writeStub(first, frequency: 220)
        try Data("not-audio".utf8).write(to: second)
        _ = try await h.runOK("attach_song", args: [
            "project_dir": dataRoot.path,
            "path": first.path,
        ])
        let audioDir = dataRoot.appendingPathComponent("audio", isDirectory: true)
        let before = try Data(contentsOf: audioDir.appendingPathComponent("first.wav"))
        let result = await h.runRaw("attach_song", args: [
            "project_dir": dataRoot.path,
            "path": second.path,
            "replace": true,
        ])

        #expect(result.isError)
        #expect(try Data(contentsOf: audioDir.appendingPathComponent("first.wav")) == before)
    }

    @Test("the explicit song anchor survives save and recovery reopen")
    func attachSongSurvivesSaveAndReopen() async throws {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent("song-reopen-\(UUID().uuidString)", isDirectory: true)
        let package = cleanup.appendingPathComponent("Project.ngv", isDirectory: true)
        let source = cleanup.appendingPathComponent("spine.wav")
        try Fixtures.prepareProjectPackage(at: package)
        _ = try ProjectScaffold.initProject(
            home: package,
            name: "reopen",
            mode: .beat
        )
        try writeStub(source)
        let h = ToolHarness()
        h.editor.projectURL = package
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let dataRoot = try #require(
            h.editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        )
        let attached = try #require(try await h.runOK(
            "attach_song",
            args: ["project_dir": dataRoot.path, "path": source.path]
        ) as? [String: Any])
        let anchorRef = try #require(attached["asset_id"] as? String)
        let anchorId = try #require(
            h.editor.mediaAssets.first { $0.id.hasPrefix(anchorRef) }?.id
        )
        let key = try #require(h.editor.openWorkingCopyKey)

        try ProjectWorkingCopy.checkpoint(
            key: key,
            snapshot: .init(
                timeline: try JSONEncoder().encode(h.editor.timeline),
                manifest: try JSONEncoder().encode(h.editor.mediaManifest),
                generationLog: try JSONEncoder().encode(h.editor.generationLog),
                thumbnail: nil,
                chatSessionFiles: []
            )
        )
        try ProjectWorkingCopy.persist(key: key, to: package)
        ProjectWorkingCopy.discard(key: key)
        let reopened = try ProjectWorkingCopy.open(
            key: key,
            packageURL: package
        )
        let manifest = try JSONDecoder().decode(
            MediaManifest.self,
            from: Data(
                contentsOf: reopened.home.appendingPathComponent(
                    Project.manifestFilename
                )
            )
        )
        let timeline = try JSONDecoder().decode(
            Timeline.self,
            from: Data(
                contentsOf: reopened.home.appendingPathComponent(
                    Project.timelineFilename
                )
            )
        )

        #expect(manifest.songAnchorAssetId == anchorId)
        #expect(manifest.intakeRoleByAssetID[anchorId] == "song")
        #expect(manifest.entries.contains { $0.id == anchorId })
        let audioTracks = timeline.tracks.filter { $0.type == .audio }
        let audioClips = audioTracks.flatMap(\.clips)
        let anchoredClips = audioClips.filter {
            $0.mediaRef == anchorId && $0.startFrame == 0
        }
        #expect(anchoredClips.count == 1)
    }

    @Test("attach_song requires exactly one of media or path")
    func attachSongExclusiveSource() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        // Neither → error.
        #expect(await h.runRaw("attach_song", args: ["project_dir": dataRoot.path]).isError)
        // Both → error.
        #expect(await h.runRaw("attach_song", args: [
            "project_dir": dataRoot.path, "media": "x", "path": "/tmp/y.wav",
        ]).isError)
    }

    @Test("show_artifact yields a markdown envelope; nothing-yet for a fresh brief")
    func showArtifact() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let shown = try await h.runOK("show_artifact", args: ["project_dir": dataRoot.path, "gate": "brief"]) as? [String: Any]
        #expect(shown?["gate"] as? String == "brief")
        #expect(shown?["markdown"] is String)

        // An unknown gate never raises — it returns the "no display artifact" note.
        let unknown = try await h.runOK("show_artifact", args: ["project_dir": dataRoot.path, "gate": "nope"]) as? [String: Any]
        #expect((unknown?["markdown"] as? String)?.contains("no display artifact") == true)
    }
}
