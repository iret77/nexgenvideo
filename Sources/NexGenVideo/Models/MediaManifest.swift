import Foundation
import NexGenEngine

struct MediaManifest: Codable, Sendable, Equatable {
    static let currentVersion = 6

    var version: Int = currentVersion
    var entries: [MediaManifestEntry] = []
    var folders: [MediaFolder] = []
    var songAnchorAssetId: String?
    var songAnchorOwnsAsset = false
    var intakeRoleByAssetID: [String: String] = [:]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([MediaManifestEntry].self, forKey: .entries) ?? []
        folders = try c.decodeIfPresent([MediaFolder].self, forKey: .folders) ?? []
        songAnchorAssetId = try c.decodeIfPresent(String.self, forKey: .songAnchorAssetId)
        songAnchorOwnsAsset = try c.decodeIfPresent(
            Bool.self,
            forKey: .songAnchorOwnsAsset
        ) ?? false
        intakeRoleByAssetID = try c.decodeIfPresent(
            [String: String].self,
            forKey: .intakeRoleByAssetID
        ) ?? [:]
        if let songAnchorAssetId {
            intakeRoleByAssetID[songAnchorAssetId] = "song"
        }
    }

    init() {}

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(max(version, Self.currentVersion), forKey: .version)
        try c.encode(entries, forKey: .entries)
        try c.encode(folders, forKey: .folders)
        try c.encodeIfPresent(songAnchorAssetId, forKey: .songAnchorAssetId)
        try c.encode(songAnchorOwnsAsset, forKey: .songAnchorOwnsAsset)
        try c.encode(intakeRoleByAssetID, forKey: .intakeRoleByAssetID)
    }

    private enum CodingKeys: String, CodingKey {
        case version, entries, folders, songAnchorAssetId, songAnchorOwnsAsset, intakeRoleByAssetID
    }
}

struct MediaManifestEntry: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var type: ClipType
    var source: MediaSource
    var duration: Double
    var generationInput: GenerationInput?
    var sourceWidth: Int?
    var sourceHeight: Int?
    var sourceFPS: Double?
    var hasAudio: Bool?
    var folderId: String?
    var cachedRemoteURL: String?
    var cachedRemoteURLExpiresAt: Date?
    var originalFilename: String? = nil
}

struct GenerationInput: Codable, Sendable, Equatable {
    var prompt: String
    /// The original user/agent intent, kept alongside the compiled `prompt` so a rerun can recompile
    /// against the CURRENT ledger instead of replaying a stale compiled prompt. Optional and
    /// backward-compatible: manifests written before this field decode with `intent == nil`, and a
    /// rerun then falls back to the stored `prompt`. (#114)
    var intent: String? = nil
    /// Exact compile-time pipeline identity. Nil only for legacy or non-shot media.
    var promptShotId: String? = nil
    var promptProjectKey: String? = nil
    var promptShotFingerprint: String? = nil
    var model: String
    var duration: Int
    var aspectRatio: String
    var resolution: String?
    var quality: String?
    var imageURLs: [String]?
    /// Image-only
    var numImages: Int?
    /// Audio-only
    var voice: String?
    var lyrics: String?
    var styleInstructions: String?
    var instrumental: Bool?
    /// Video-only
    var generateAudio: Bool?
    var referenceImageURLs: [String]?
    var referenceVideoURLs: [String]?
    var referenceAudioURLs: [String]?

    /// Asset IDs for the references.
    var imageURLAssetIds: [String]?
    var referenceImageAssetIds: [String]?
    var referenceVideoAssetIds: [String]?
    var referenceAudioAssetIds: [String]?
    var spendTransactionId: String?
    var createdAt: Date?
    var sourceVideoAssetId: String?
    var startFrameAssetId: String?
    var endFrameAssetId: String?
    /// Video-only duration selection. Nil decodes legacy manifests as `.seconds(duration)`.
    var videoDuration: VideoDuration? = nil
    /// Exact host-owned route and ordered conditioning inputs for a pipeline generation.
    var productionRouting: ProductionGenerationRoutingProofV1? = nil
}

struct ProductionGenerationRoutingBindingV1: Codable, Sendable, Equatable {
    let demandID: String
    let graphAssetID: String
    let graphAssetVersion: Int
    let mediaAssetID: String
    let path: String
    let sha256: String
    let modalityID: String
    let semanticJobID: String
    let inputSlotID: String
    let modeID: String

    private enum CodingKeys: String, CodingKey {
        case demandID = "demand_id"
        case graphAssetID = "graph_asset_id"
        case graphAssetVersion = "graph_asset_version"
        case mediaAssetID = "media_asset_id"
        case path
        case sha256
        case modalityID = "modality_id"
        case semanticJobID = "semantic_job_id"
        case inputSlotID = "input_slot_id"
        case modeID = "mode_id"
    }
}

struct ProductionGenerationRoutingProofV1: Codable, Sendable, Equatable {
    static let schemaVersion = "production-generation-routing/v1"

    let schema: String
    let projectID: String
    let shotID: String
    let modelID: String
    let providerID: String
    let transportID: String
    let endpointID: String
    let modelParam: String?
    let offeringID: String
    let requirement: ProductionRequirementV1
    let route: ProductionRouteV1
    let referencePlan: ReferencePlanV2
    let routeArtifactSHA256: String
    let requirementSHA256: String
    let capabilitiesSHA256: String
    let routeSHA256: String
    let referencePlanSHA256: String
    let orderedBindingsSHA256: String
    let orderedBindings: [ProductionGenerationRoutingBindingV1]
    let historicalAssetGraph: AssetGraphV1?
    let historicalDemandSet: ReferenceDemandSetV1?
    let offeringCapabilities: ResolvedVideoOfferingCapabilitiesV1
    let offeringCapabilitiesSHA256: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case projectID = "project_id"
        case shotID = "shot_id"
        case modelID = "model_id"
        case providerID = "provider_id"
        case transportID = "transport_id"
        case endpointID = "endpoint_id"
        case modelParam = "model_param"
        case offeringID = "offering_id"
        case requirement
        case route
        case referencePlan = "reference_plan"
        case routeArtifactSHA256 = "route_artifact_sha256"
        case requirementSHA256 = "requirement_sha256"
        case capabilitiesSHA256 = "capabilities_sha256"
        case routeSHA256 = "route_sha256"
        case referencePlanSHA256 = "reference_plan_sha256"
        case orderedBindingsSHA256 = "ordered_bindings_sha256"
        case orderedBindings = "ordered_bindings"
        case historicalAssetGraph = "historical_asset_graph"
        case historicalDemandSet = "historical_demand_set"
        case offeringCapabilities = "offering_capabilities"
        case offeringCapabilitiesSHA256 = "offering_capabilities_sha256"
    }

    init(
        projectID: String,
        shotID: String,
        modelID: String,
        providerID: String,
        transportID: String,
        endpointID: String,
        modelParam: String?,
        offeringID: String,
        requirement: ProductionRequirementV1,
        route: ProductionRouteV1,
        referencePlan: ReferencePlanV2,
        routeArtifactSHA256: String,
        requirementSHA256: String,
        capabilitiesSHA256: String,
        routeSHA256: String,
        referencePlanSHA256: String,
        orderedBindingsSHA256: String,
        orderedBindings: [ProductionGenerationRoutingBindingV1],
        offeringCapabilities: ResolvedVideoOfferingCapabilitiesV1,
        offeringCapabilitiesSHA256: String,
        historicalAssetGraph: AssetGraphV1? = nil,
        historicalDemandSet: ReferenceDemandSetV1? = nil
    ) {
        schema = Self.schemaVersion
        self.projectID = projectID
        self.shotID = shotID
        self.modelID = modelID
        self.providerID = providerID
        self.transportID = transportID
        self.endpointID = endpointID
        self.modelParam = modelParam
        self.offeringID = offeringID
        self.requirement = requirement
        self.route = route
        self.referencePlan = referencePlan
        self.routeArtifactSHA256 = routeArtifactSHA256
        self.requirementSHA256 = requirementSHA256
        self.capabilitiesSHA256 = capabilitiesSHA256
        self.routeSHA256 = routeSHA256
        self.referencePlanSHA256 = referencePlanSHA256
        self.orderedBindingsSHA256 = orderedBindingsSHA256
        self.orderedBindings = orderedBindings
        self.historicalAssetGraph = historicalAssetGraph
        self.historicalDemandSet = historicalDemandSet
        self.offeringCapabilities = offeringCapabilities
        self.offeringCapabilitiesSHA256 = offeringCapabilitiesSHA256
    }

    func matches(_ target: ResolvedGenerationTarget) -> Bool {
        modelID == target.modelId
            && providerID == target.provider.rawValue
            && transportID == target.transport.rawValue
            && endpointID == target.endpoint
            && modelParam == target.binding?.modelParam
            && offeringCapabilities == target.binding?.resolvedVideoCapabilities
    }
}

enum MediaSource: Codable, Sendable, Equatable {
    case external(absolutePath: String)
    case project(relativePath: String)
}
