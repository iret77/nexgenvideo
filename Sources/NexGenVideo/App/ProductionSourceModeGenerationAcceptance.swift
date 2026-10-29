import AppKit
import NexGenEngine

@MainActor
final class ProductionSourceModeGenerationAcceptance {
    let kind: ProductionSourceModesOwnerAcceptance.Kind
    let catalog = ModelCatalog()
    let first: ProductionV2GenerationAcceptance
    let activation: ProviderActivation
    let session: URLSession
    let modelID: String

    var candidates: [CatalogProductionRouteCandidate] {
        catalog.productionRouteCandidates(activation: activation).filter { $0.modelID == modelID || $0.modelID == first.modelID }
    }

    init(kind: ProductionSourceModesOwnerAcceptance.Kind, driver: ProductionVisualSourcesDriver) async throws {
        guard WorkspaceUIAcceptance.isRequested else { throw GateBlocked("Source generation is confined to isolated native acceptance.") }
        self.kind = kind
        first = try ProductionV2GenerationAcceptance()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        switch kind {
        case .aiEnhanced:
            modelID = "runway/aleph2"
            activation = ProviderActivation(active: [.init(provider: .fal, transport: .api), .init(provider: .runway, transport: .api)])
            configuration.protocolClasses = [ProductionRunwaySourceHTTP.self]
            ProductionRunwaySourceHTTP.install(operation: .transform, output: Data())
        case .nativeExtension:
            modelID = "runway/seedance2_5"
            activation = ProviderActivation(active: [.init(provider: .fal, transport: .api), .init(provider: .runway, transport: .api)])
            configuration.protocolClasses = [ProductionRunwaySourceHTTP.self]
            ProductionRunwaySourceHTTP.install(operation: .extend, output: Data())
        case .frameContinuation:
            modelID = "bytedance/seedance-2.5/image-to-video"
            activation = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
            configuration.protocolClasses = [ManualVideoModesHTTP.self]
        case .animatedStill:
            throw GateBlocked("Animated still uses its actual Frames image and has no final video-generation helper.")
        }
        session = URLSession(configuration: configuration)
        catalog.load(entries: ModelCatalog.launchEntries)
        if kind != .frameContinuation {
            let offered = try await RunwayClient(apiKey: "simulator-only-key", session: session).availableModelIds()
            let discovered = RunwayModelRegistry.discoveredEntries(availableModelIds: offered)
            catalog.applyDiscovered(discovered, for: .runway)
            catalog.setProviderDiscoveryState(.ready(modelCount: discovered.count), for: .runway)
            guard ProductionRunwaySourceHTTP.unexpectedRequests.isEmpty,
                  ProductionRunwaySourceHTTP.requests.count == 1,
                  ProductionRunwaySourceHTTP.requests.first?.url == "https://api.dev.runwayml.com/v1/organization" else {
                throw GateBlocked("The isolated account model response bypassed the actual Runway client.")
            }
            try driver.record("actual source-video catalog through isolated HTTP", fields: ["accountModelIDs": offered.sorted(),
                "registeredModelIDs": discovered.map(\.id), "operation": kind.rawValue, "liveProvider": false,
                "actualAccountEntitlementClaim": false])
        }
        guard candidates.contains(where: { $0.modelID == modelID && $0.target != nil && $0.candidate.providerActivated && $0.candidate.liveAvailable }) else {
            throw GateBlocked("The actual native catalog cannot execute this source-video recipe.")
        }
    }

    func close() {
        session.invalidateAndCancel(); first.close(); ProductionRunwaySourceHTTP.clear(); ManualVideoModesHTTP.clear()
    }

    func executor(editor: EditorViewModel) -> ToolExecutor {
        ToolExecutor(editor: editor, providerActivation: { self.activation }, modelCatalog: catalog,
            productionRouteCandidates: { _ in self.candidates }, catalogReadiness: { true }, isModelEnabled: { _ in true },
            generationQuoteLoader: { _, _ in throw GenerationBackendError.transport("The isolated provider has no live monetary quote.") })
    }

    func configure(editor: EditorViewModel) {
        editor.generationService.reconciliation = ProviderRunReconciliation(session: session,
            providerKey: { $0 == .fal || $0 == .runway ? "simulator-only-key" : nil }, falCharge: { _, _, _ in nil })
        editor.generationBatchCoordinator.catalogReadiness = {}
        editor.generationBatchCoordinator.providerActivation = { self.activation }
        editor.generationBatchCoordinator.modelCatalog = catalog
        editor.generationBatchCoordinator.quoteLoader = { _, _ in throw GenerationBackendError.transport("The isolated provider has no live monetary quote.") }
    }

    func proposal(shotID: String, context: ProductionPlanningAcceptanceFixture.Context) async throws -> PipelineProductionPlanWriter.ShotProposal {
        let root = context.dataRoot
        let (board, snapshot) = try await Task.detached {
            (try PlanningWriterIO.storyboard(dataRoot: root), try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: root))
        }.value
        guard let intent = snapshot.draft.shots.first(where: { $0.shotID == shotID }),
              let planned = board.timing.shots.first(where: { $0.id == shotID }),
              let candidate = candidates.first(where: { $0.modelID == modelID }),
              let target = candidate.target else { throw GateBlocked("The selected native source recipe has no actual plan or provider offering.") }
        let slot = kind == .frameContinuation ? CoreReferenceInputSlotIDV1.firstFrame : CoreReferenceInputSlotIDV1.sourceVideo
        guard let mode = candidate.candidate.inputSlots.first(where: { $0.id == slot })?.modeIDs.first else {
            throw GateBlocked("The actual offering has no executable native source input slot.")
        }
        let sourceAssetID: String?
        let nativeTicks: Int64
        let inputs: ProductionCoreInputModesV1
        switch kind {
        case .aiEnhanced:
            guard intent.sourceMode == .aiEnhanced, let source = intent.source, let range = intent.sourceInputRange,
                  range.timebase == board.timing.timebase,
                  let asset = snapshot.assets.first(where: { $0.path == source.path && $0.sha256 == source.sha256 }) else {
                throw GateBlocked("AI-enhanced output needs the exact natively selected original source and range.")
            }
            sourceAssetID = asset.id
            nativeTicks = range.durationTicks
            inputs = .init(sourceVideoModeID: mode)
        case .nativeExtension:
            guard intent.chainKind == .nativeExtension, intent.sourceMode == .generated else { throw GateBlocked("The draft did not natively choose video extension.") }
            sourceAssetID = PipelineProductionPlanWriter.predecessorVideoRecipe(shotID: shotID)
            nativeTicks = 8 * board.timing.timebase.ticksPerSecond
            inputs = .init(sourceVideoModeID: mode)
            guard target.binding?.resolvedVideoCapabilities?.inputPolicy.sourceOperation == .extendForward else { throw GateBlocked("Transform is not executable forward extension.") }
        case .frameContinuation:
            guard intent.chainKind == .frameContinuation, intent.sourceMode == .generated else { throw GateBlocked("The draft did not natively choose frame continuation.") }
            sourceAssetID = nil
            nativeTicks = 8 * board.timing.timebase.ticksPerSecond
            inputs = .init(predecessorLastFrameModeID: mode)
        case .animatedStill: throw GateBlocked("Still has no final video-generation requirement.")
        }
        let steps = Dictionary(uniqueKeysWithValues: board.storyboard.steps.map { ($0.id, $0) })
        let action = try planned.stepIDs.map { id in
            guard let step = steps[id] else { throw GateBlocked("The native source recipe lost its canonical action.") }
            return step.action
        }.joined(separator: "\n")
        let sourceIn = board.timing.timebase.ticksPerSecond
        guard nativeTicks >= planned.durationTicks + 2 * sourceIn else { throw GateBlocked("This actual provider output must contain both explicit review handles around its planned cut.") }
        let duration = board.timing.timebase.seconds(for: nativeTicks)
        let shot = ExecutionShotV1(id: shotID, sourceMode: kind == .aiEnhanced ? .aiEnhanced : .generated,
            startState: .init(summary: "The approved source movement begins."),
            endState: .init(summary: "The source movement reaches its planned final composition."), primaryAction: action,
            camera: .init(movementID: intent.camera.movement.rawValue, movementDetail: intent.camera.movementDetail,
                framingID: intent.camera.framing.scale), renderability: .green,
            acceptance: [.init(id: "exact-source", requirement: "Use the exact approved native source recipe without substituting another asset.", severity: "error")],
            generationRequirement: .init(modalityID: "video", modeIDs: [mode], visibleEntityCount: 0,
                requiresFirstFrame: kind == .frameContinuation, sourceVideoAssetID: sourceAssetID,
                duration: .init(preferredSeconds: duration, minimumSeconds: duration, maximumSeconds: duration),
                resolution: kind == .frameContinuation ? "720p" : nil, aspectRatio: "16:9"))
        return .init(execution: shot, nativeDurationTicks: nativeTicks, sourceInTicks: sourceIn, sourceInputRange: nil,
            coreInputs: inputs, referenceDemands: [], selectedModelID: modelID, selectedOffering: candidate.candidate.capabilities.offering)
    }
}
