import Foundation

struct MediaManifest: Codable, Sendable, Equatable {
    static let currentVersion = 5

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
}

enum MediaSource: Codable, Sendable, Equatable {
    case external(absolutePath: String)
    case project(relativePath: String)
}
