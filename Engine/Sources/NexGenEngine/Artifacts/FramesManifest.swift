import Foundation

public let framesSchemaVersion = "frames/v1"

/// Per-frame generation manifest — records each generated keyframe together with the
/// EXACT prompt sent to the image provider (`provider_prompt`), for reproducibility +
/// audit and for the frame sanity checks (ratio / size / builder-bypass). Generic like
/// `RenderManifest`: the app's frame-recording path writes it, a format pack's checks
/// read it. Port of `frames/schema.py::FramesManifest`. Frames are nested under
/// `shots[].frames[]` with a `role` (start/end) — the shot id lives on the parent
/// `ShotFrames`, not the frame. `path` is relative to the pipeline data root.
public struct FramesManifest: Codable, Sendable, Equatable {
    public var schema: String
    public var project: String
    public var generated: String
    /// "per_shot" | "per_section" | "all_at_once".
    public var approvalMode: String
    public var shots: [ShotFrames]

    public init(schema: String = framesSchemaVersion, project: String, generated: String,
                approvalMode: String = "per_shot", shots: [ShotFrames] = []) {
        self.schema = schema
        self.project = project
        self.generated = generated
        self.approvalMode = approvalMode
        self.shots = shots
    }

    private enum CodingKeys: String, CodingKey {
        case schema, project, generated
        case approvalMode = "approval_mode"
        case shots
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? framesSchemaVersion
        project = try c.decode(String.self, forKey: .project)
        generated = try c.decode(String.self, forKey: .generated)
        approvalMode = try c.decodeIfPresent(String.self, forKey: .approvalMode) ?? "per_shot"
        shots = try c.decodeIfPresent([ShotFrames].self, forKey: .shots) ?? []
    }

    /// The `ShotFrames` for a shot id, or nil. Port of `FramesManifest.shot`.
    public func shot(_ shotId: String) -> ShotFrames? { shots.first { $0.shotId == shotId } }
}

public struct ShotFrames: Codable, Sendable, Equatable {
    public var shotId: String
    /// "none" | "start" | "start_end".
    public var keyframeStrategy: String
    public var frames: [FrameEntry]

    public init(shotId: String, keyframeStrategy: String, frames: [FrameEntry] = []) {
        self.shotId = shotId
        self.keyframeStrategy = keyframeStrategy
        self.frames = frames
    }

    private enum CodingKeys: String, CodingKey {
        case shotId = "shot_id"
        case keyframeStrategy = "keyframe_strategy"
        case frames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shotId = try c.decode(String.self, forKey: .shotId)
        keyframeStrategy = try c.decodeIfPresent(String.self, forKey: .keyframeStrategy) ?? "start"
        frames = try c.decodeIfPresent([FrameEntry].self, forKey: .frames) ?? []
    }
}

public struct FrameEntry: Codable, Sendable, Equatable {
    /// "start" | "end".
    public var role: String
    /// Image path, relative to the pipeline data root.
    public var path: String
    /// Human log memo — NOT the provider prompt.
    public var prompt: String
    /// Image-provider model id.
    public var runwayModel: String
    public var approved: Bool
    /// The EXACT string sent to the image provider. Empty only for legacy / bypassed
    /// frames — which is what `builder_bypass` flags.
    public var providerPrompt: String
    public var multiRefHints: [String]

    public init(role: String, path: String, prompt: String = "", runwayModel: String = "",
                approved: Bool = false, providerPrompt: String = "", multiRefHints: [String] = []) {
        self.role = role
        self.path = path
        self.prompt = prompt
        self.runwayModel = runwayModel
        self.approved = approved
        self.providerPrompt = providerPrompt
        self.multiRefHints = multiRefHints
    }

    private enum CodingKeys: String, CodingKey {
        case role, path, prompt
        case runwayModel = "runway_model"
        case approved
        case providerPrompt = "provider_prompt"
        case multiRefHints = "multi_ref_hints"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        path = try c.decode(String.self, forKey: .path)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        runwayModel = try c.decodeIfPresent(String.self, forKey: .runwayModel) ?? ""
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved) ?? false
        providerPrompt = try c.decodeIfPresent(String.self, forKey: .providerPrompt) ?? ""
        multiRefHints = try c.decodeIfPresent([String].self, forKey: .multiRefHints) ?? []
    }
}

/// Load `frames/manifest.json` from the data root. Mirrors `loadRenderManifest`.
public func loadFramesManifest(dataRoot: URL) throws -> FramesManifest {
    try JSONArtifactStore(dataRoot: dataRoot).load(FramesManifest.self, at: PipelineLayout.framesManifestFile)
}

/// Persist `frames/manifest.json` to the data root (sorted keys, atomic).
public func saveFramesManifest(_ manifest: FramesManifest, dataRoot: URL) throws {
    try JSONArtifactStore(dataRoot: dataRoot).save(manifest, to: PipelineLayout.framesManifestFile)
}
