import Foundation
import ImageIO
import NexGenEngine
import UniformTypeIdentifiers

struct FilmFlowProjectSummary: Codable, Equatable, Sendable, Identifiable {
    let projectId: String
    let title: String
    let phase: String
    let state: String
    let role: String
    let updatedAt: String
    var id: String { projectId }
}

struct FilmFlowProject: Codable, Equatable, Sendable {
    struct Version: Codable, Equatable, Sendable { let versionNumber: Int; let label: String; let state: String }
    struct Counts: Codable, Equatable, Sendable { let scenes: Int; let shots: Int; let entities: Int }
    let projectId: String
    let title: String
    let phase: String
    let state: String
    let role: String
    let styleBible: String?
    let aspectRatio: String
    let sketchStyle: String
    let shotNumberingScheme: String
    let documentLanguage: String?
    let activeScriptVersion: Version?
    let counts: Counts
}

struct FilmFlowScene: Codable, Equatable, Sendable {
    let sceneNumber: String
    let heading: String
    let intExt: String?
    let timeOfDay: String?
    let shortTitle: String?
    let pageStart: Double?
    let pageEnd: Double?
    let shotCount: Int
}

struct FilmFlowShotlist: Codable, Equatable, Sendable {
    struct Project: Codable, Equatable, Sendable {
        let title: String; let shotNumberingScheme: String; let aspectRatio: String; let sketchStyle: String
    }
    struct Scene: Codable, Equatable, Sendable {
        let sceneNumber: String; let heading: String; let intExt: String?; let timeOfDay: String?
        var shots: [Shot]
    }
    struct Shot: Codable, Equatable, Sendable {
        struct Camera: Codable, Equatable, Sendable {
            let move: String?; let moveIntensity: String?; let moveNotes: String?
            let lensMm: Double?; let height: String?; let angle: String?; let support: String?; let framingNotes: String?
        }
        struct Lighting: Codable, Equatable, Sendable { let mood: String?; let complexity: String?; let notes: String? }
        struct Staging: Codable, Equatable, Sendable { let intent: String?; let notes: String? }
        struct Target: Codable, Equatable, Sendable { let name: String; let type: String }
        let shotLabel: String
        let shotType: String
        let variant: String?
        let description: String?
        let camera: Camera
        let lighting: Lighting
        let staging: Staging
        let durationSeconds: Double?
        let charactersInFrame: [String]
        let targetEntity: Target?
        var storyboardImageUrl: String?
    }
    let project: Project
    let scriptVersion: FilmFlowProject.Version?
    var scenes: [Scene]
}

struct FilmFlowEntity: Codable, Equatable, Sendable {
    let name: String
    let type: String
    let aliases: [String]
    let visualDescription: String?
    var referenceImageUrl: String?
    let notes: String?
    let isConfirmed: Bool
}

struct FilmFlowSnapshot: Codable, Equatable, Sendable {
    struct Response: Codable, Equatable, Sendable {
        let tool: String
        let argumentsSHA256: String
        let toolSchemaSHA256: String
        let sourceObservationUTF8SHA256: String
        let sourceObservationUTF8Count: Int
        let sourceObservationEncoding: String
        let portablePath: String
        let portableDTOSHA256: String
        let omissions: [String]
        let imagePointers: [String]
    }
    struct Image: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let pointers: [String]
        let path: String
        let sha256: String
        let byteCount: Int
        let width: Int
        let height: Int
        let contentType: String
    }
    struct MissingImage: Codable, Equatable, Sendable, Identifiable {
        let pointer: String
        let reason: String
        var id: String { pointer }
    }
    let schema: String
    let id: UUID
    let resource: URL
    let startedAt: Date
    let finishedAt: Date
    let project: FilmFlowProjectSummary
    let noActiveScript: Bool
    let responses: [Response]
    let images: [Image]
    let missingImages: [MissingImage]

    struct Prepared: Sendable {
        let snapshot: FilmFlowSnapshot
        let directory: URL
        let manifestSHA256: String
        func discard() { try? FileManager.default.removeItem(at: directory) }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from bytes: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: bytes)
    }

    static func omissions(original: Data, portable: Data) throws -> [String] {
        func escape(_ key: String) -> String { key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
        func walk(_ source: Any, _ target: Any?, _ path: String) -> [String] {
            if let object = source as? [String: Any] {
                let result = target as? [String: Any] ?? [:]
                return object.keys.sorted().flatMap { key in
                    let next = path + "/" + escape(key)
                    guard let value = result[key] else { return [next] }
                    return walk(object[key]!, value, next)
                }
            }
            if let array = source as? [Any] {
                let result = target as? [Any] ?? []
                return array.indices.flatMap { i in walk(array[i], i < result.count ? result[i] : nil, path + "/\(i)") }
            }
            return []
        }
        return walk(try JSONSerialization.jsonObject(with: original), try JSONSerialization.jsonObject(with: portable), "")
    }

    static func image(bytes: Data, pointers: [String]) throws -> Image {
        guard !bytes.isEmpty, bytes.count <= FilmFlowHTTP.maximumBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, let uti = UTType(type),
              [UTType.png, .jpeg, .tiff, .heic, .webP].contains(uti),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              Int64(width) * Int64(height) <= 67_108_864,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil), decoded.width == width, decoded.height == height,
              let ext = uti.preferredFilenameExtension else {
            throw FilmFlowFailure.message("FilmFlow supplied an unsupported or unreadable image.")
        }
        let sha = FileDigest.sha256(of: bytes)
        return Image(id: sha, pointers: pointers.sorted(), path: "images/\(sha).\(ext)", sha256: sha,
                     byteCount: bytes.count, width: width, height: height, contentType: type)
    }

    static func verify(directory: URL, expectedSHA256: String? = nil) throws -> FilmFlowSnapshot {
        let manifest = try ProjectLocalFile.resolve("snapshot.v1.json", dataRoot: directory)
        let bytes = try Data(contentsOf: manifest)
        if let expectedSHA256, FileDigest.sha256(of: bytes) != expectedSHA256 {
            throw FilmFlowFailure.message("The retained FilmFlow snapshot changed.")
        }
        let value = try decode(Self.self, from: bytes)
        guard value.schema == "ngv.filmflow-snapshot.v1", value.resource == FilmFlowHTTP.endpoint,
              value.startedAt <= value.finishedAt, value.responses.count == (value.noActiveScript ? 2 : 4),
              Set(value.responses.map(\.tool)) == Set(value.noActiveScript ? ["get_project", "list_entities"] : ["get_project", "list_scenes", "get_shotlist", "list_entities"]),
              Set(value.images.map(\.id)).count == value.images.count else {
            throw FilmFlowFailure.message("The retained FilmFlow snapshot is invalid.")
        }
        for response in value.responses {
            guard response.portablePath == "dto/\(response.tool).json", response.sourceObservationUTF8Count > 0,
                  response.sourceObservationEncoding == "sdk-decoded-text-utf8",
                  response.sourceObservationUTF8SHA256.count == 64, response.toolSchemaSHA256.count == 64,
                  response.argumentsSHA256.count == 64, response.omissions == response.omissions.sorted(),
                  Set(response.omissions).count == response.omissions.count else {
                throw FilmFlowFailure.message("The FilmFlow response inventory is invalid.")
            }
            _ = try ProjectLocalFile.requireHash(response.portableDTOSHA256, at: response.portablePath, dataRoot: directory)
            _ = try ProjectLocalFile.requireHash(response.toolSchemaSHA256, at: "schemas/\(response.tool).json", dataRoot: directory)
            guard response.argumentsSHA256 == FileDigest.sha256(of: try encode(["projectId": value.project.projectId])) else {
                throw FilmFlowFailure.message("The FilmFlow tool arguments changed.")
            }
        }
        var pointers = Set<String>()
        for item in value.images {
            let url = try ProjectLocalFile.requireHash(item.sha256, at: item.path, dataRoot: directory)
            let actual = try image(bytes: Data(contentsOf: url), pointers: item.pointers)
            guard actual == item, !item.pointers.isEmpty, item.pointers.allSatisfy({ pointers.insert($0).inserted }) else {
                throw FilmFlowFailure.message("A retained FilmFlow image or mapping changed.")
            }
        }
        for item in value.missingImages {
            guard !item.reason.isEmpty, pointers.insert(item.pointer).inserted else {
                throw FilmFlowFailure.message("The FilmFlow image omission inventory is invalid.")
            }
        }
        guard pointers == Set(value.responses.flatMap(\.imagePointers)),
              value.responses.flatMap(\.imagePointers).count == pointers.count else {
            throw FilmFlowFailure.message("The FilmFlow image inventory is incomplete.")
        }
        let entities: [FilmFlowEntity] = try read("list_entities", in: directory)
        try requireCanonical(entities, tool: "list_entities", directory: directory)
        guard entities.allSatisfy({ $0.referenceImageUrl == nil }) else {
            throw FilmFlowFailure.message("A retained FilmFlow response contains a remote image address.")
        }
        if !value.noActiveScript {
            let scenes: [FilmFlowScene] = try read("list_scenes", in: directory)
            try requireCanonical(scenes, tool: "list_scenes", directory: directory)
            let shots: FilmFlowShotlist = try read("get_shotlist", in: directory)
            try requireCanonical(shots, tool: "get_shotlist", directory: directory)
            guard shots.scenes.flatMap(\.shots).allSatisfy({ $0.storyboardImageUrl == nil }) else {
                throw FilmFlowFailure.message("A retained FilmFlow response contains a remote image address.")
            }
        }
        let project: FilmFlowProject = try read("get_project", in: directory)
        try requireCanonical(project, tool: "get_project", directory: directory)
        guard project.projectId == value.project.projectId, (project.activeScriptVersion == nil) == value.noActiveScript else {
            throw FilmFlowFailure.message("The FilmFlow project binding changed.")
        }
        let expectedPaths = Set(["snapshot.v1.json"] + value.responses.flatMap { [$0.portablePath, "schemas/\($0.tool).json"] } + value.images.map(\.path))
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
            throw FilmFlowFailure.message("The FilmFlow snapshot inventory cannot be read.")
        }
        var actualPaths = Set<String>()
        for case let file as URL in enumerator {
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            let path = String(file.path.dropFirst(directory.path.count + 1))
            guard properties.isSymbolicLink != true,
                  (properties.isDirectory == true ? ["dto", "schemas", "images"].contains(path) : properties.isRegularFile == true) else {
                throw FilmFlowFailure.message("The FilmFlow snapshot contains an unsupported entry.")
            }
            if properties.isRegularFile == true { actualPaths.insert(path) }
        }
        guard actualPaths == expectedPaths else { throw FilmFlowFailure.message("The FilmFlow snapshot contains unlisted or missing files.") }
        return value
    }

    private static func requireCanonical<T: Encodable>(_ value: T, tool: String, directory: URL) throws {
        guard try encode(value) == Data(contentsOf: ProjectLocalFile.resolve("dto/\(tool).json", dataRoot: directory)) else {
            throw FilmFlowFailure.message("The portable FilmFlow data contains unsupported fields or changed encoding.")
        }
    }

    static func read<T: Decodable>(_ tool: String, in directory: URL) throws -> T {
        try decode(T.self, from: Data(contentsOf: ProjectLocalFile.resolve("dto/\(tool).json", dataRoot: directory)))
    }
}
