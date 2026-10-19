import Foundation
import MCP
import NexGenEngine

actor FilmFlowReader {
    private let client: MCPProviderClient
    private let connection: FilmFlowOAuth.Connection
    private var tools: [String: MCPProviderClient.DiscoveredTool] = [:]
    private let requireConnection: @Sendable (FilmFlowOAuth.Connection) async throws -> Void
    private let downloadImage: @Sendable (URL) async throws -> RemoteMediaDownloader.Download

    init(connection: FilmFlowOAuth.Connection, client: MCPProviderClient? = nil,
         requireConnection: @escaping @Sendable (FilmFlowOAuth.Connection) async throws -> Void = { try await FilmFlowOAuth.shared.requireCurrent($0) },
         downloadImage: @escaping @Sendable (URL) async throws -> RemoteMediaDownloader.Download = {
             try await RemoteMediaDownloader.download($0, maxBytes: Int64(FilmFlowHTTP.maximumBytes), timeout: 90)
         }) {
        self.connection = connection
        self.requireConnection = requireConnection; self.downloadImage = downloadImage
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FilmFlowPinnedProtocol.self]
        self.client = client ?? MCPProviderClient(config: .init(endpoint: FilmFlowHTTP.endpoint, bearerToken: connection.tokens.accessToken),
            urlSession: URLSession(configuration: configuration), legacyTransportFactory: FilmFlowHTTP.transport)
    }

    func close() async { await client.disconnect() }

    func projects() async throws -> [FilmFlowProjectSummary] {
        let discovered = try await cancellable { try await self.client.discoverTools() }
        guard Set(discovered.map(\.name)).count == discovered.count else {
            throw FilmFlowFailure.message("FilmFlow returned duplicate tool names.")
        }
        tools = Dictionary(uniqueKeysWithValues: discovered.map { ($0.name, $0) })
        for name in ["list_projects", "get_project", "list_scenes", "get_shotlist", "list_entities"] {
            guard let tool = tools[name], case .object(let schema) = tool.inputSchema,
                  schema["type"] == .string("object") else {
                throw FilmFlowFailure.message("FilmFlow does not expose the required read tools.")
            }
        }
        let bytes = try await response("list_projects", project: nil)
        let projects = try FilmFlowSnapshot.decode([FilmFlowProjectSummary].self, from: bytes)
        guard Set(projects.map(\.projectId)).count == projects.count,
              projects.allSatisfy({ !$0.projectId.isEmpty && !$0.title.isEmpty }) else {
            throw FilmFlowFailure.message("FilmFlow returned an ambiguous project list.")
        }
        return projects
    }

    func capture(project selected: FilmFlowProjectSummary) async throws -> FilmFlowSnapshot.Prepared {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-filmflow-" + id.uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("dto"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("schemas"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
        do {
            let started = Date()
            let projectBytes = try await response("get_project", project: selected.projectId)
            let detail = try FilmFlowSnapshot.decode(FilmFlowProject.self, from: projectBytes)
            guard detail.projectId == selected.projectId else { throw changed() }
            var responses: [FilmFlowSnapshot.Response] = []
            var urls: [(String, URL)] = []
            var missing: [FilmFlowSnapshot.MissingImage] = []
            func retain<T: Encodable>(_ name: String, original: Data, value: T, imagePointers: [String] = []) throws {
                guard let tool = tools[name] else { throw FilmFlowFailure.message("Read FilmFlow projects before capturing a snapshot.") }
                let portable = try FilmFlowSnapshot.encode(value)
                let schema = try FilmFlowSnapshot.encode(tool.inputSchema)
                let path = "dto/\(name).json"
                try portable.write(to: directory.appendingPathComponent(path), options: .atomic)
                try schema.write(to: directory.appendingPathComponent("schemas/\(name).json"), options: .atomic)
                responses.append(.init(tool: name,
                    argumentsSHA256: FileDigest.sha256(of: try FilmFlowSnapshot.encode(["projectId": selected.projectId])),
                    toolSchemaSHA256: FileDigest.sha256(of: schema), sourceObservationUTF8SHA256: FileDigest.sha256(of: original),
                    sourceObservationUTF8Count: original.count, sourceObservationEncoding: "sdk-decoded-text-utf8", portablePath: path,
                    portableDTOSHA256: FileDigest.sha256(of: portable),
                    omissions: try FilmFlowSnapshot.omissions(original: original, portable: portable).sorted(), imagePointers: imagePointers.sorted()))
            }
            func imageURL(_ raw: String, pointer: String) {
                guard let url = URL(string: raw), (try? FilmFlowHTTP.requireHTTPS(url)) != nil else {
                    missing.append(.init(pointer: pointer, reason: "The image address is not supported.")); return
                }
                urls.append((pointer, url))
            }
            try retain("get_project", original: projectBytes, value: detail)
            if detail.activeScriptVersion != nil {
                let scenes = try await response("list_scenes", project: selected.projectId)
                try retain("list_scenes", original: scenes, value: FilmFlowSnapshot.decode([FilmFlowScene].self, from: scenes))
                let shots = try await response("get_shotlist", project: selected.projectId)
                var shotlist = try FilmFlowSnapshot.decode(FilmFlowShotlist.self, from: shots)
                guard shotlist.scriptVersion == detail.activeScriptVersion else { throw changed() }
                var pointers: [String] = []
                for scene in shotlist.scenes.indices {
                    for shot in shotlist.scenes[scene].shots.indices {
                        if let raw = shotlist.scenes[scene].shots[shot].storyboardImageUrl {
                            let pointer = "get_shotlist#/scenes/\(scene)/shots/\(shot)/storyboardImageUrl"
                            pointers.append(pointer); imageURL(raw, pointer: pointer)
                            shotlist.scenes[scene].shots[shot].storyboardImageUrl = nil
                        }
                    }
                }
                try retain("get_shotlist", original: shots, value: shotlist, imagePointers: pointers)
            }
            let entityBytes = try await response("list_entities", project: selected.projectId)
            var entities = try FilmFlowSnapshot.decode([FilmFlowEntity].self, from: entityBytes)
            var entityPointers: [String] = []
            for index in entities.indices {
                if let raw = entities[index].referenceImageUrl {
                    let pointer = "list_entities#/\(index)/referenceImageUrl"
                    entityPointers.append(pointer); imageURL(raw, pointer: pointer)
                    entities[index].referenceImageUrl = nil
                }
            }
            try retain("list_entities", original: entityBytes, value: entities, imagePointers: entityPointers)
            var images: [String: FilmFlowSnapshot.Image] = [:]
            var downloadedBytes = 0
            for (pointer, url) in urls {
                try Task.checkCancellation()
                do {
                    let download = try await downloadImage(url)
                    defer { try? FileManager.default.removeItem(at: download.temporaryURL) }
                    let bytes = try Data(contentsOf: download.temporaryURL)
                    downloadedBytes += bytes.count
                    guard downloadedBytes <= 256 * 1_024 * 1_024 else {
                        throw FilmFlowFailure.message("This FilmFlow snapshot exceeds the total image transfer limit.")
                    }
                    let item = try FilmFlowSnapshot.image(bytes: bytes, pointers: [pointer])
                    let merged = try FilmFlowSnapshot.image(bytes: bytes, pointers: (images[item.id]?.pointers ?? []) + [pointer])
                    images[item.id] = merged
                    try bytes.write(to: directory.appendingPathComponent(item.path), options: .atomic)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if downloadedBytes > 256 * 1_024 * 1_024 { throw error }
                    missing.append(.init(pointer: pointer, reason: "The image could not be downloaded and decoded. Capture again or explicitly omit it."))
                }
            }
            let endingProject = try FilmFlowSnapshot.decode(FilmFlowProject.self,
                from: await response("get_project", project: selected.projectId))
            let endingList = try FilmFlowSnapshot.decode([FilmFlowProjectSummary].self,
                from: await response("list_projects", project: nil))
            guard try FilmFlowSnapshot.encode(detail) == FilmFlowSnapshot.encode(endingProject),
                  endingList.filter({ $0.projectId == selected.projectId }).count == 1,
                  try FilmFlowSnapshot.encode(selected) == FilmFlowSnapshot.encode(endingList.first { $0.projectId == selected.projectId }) else { throw changed() }
            try await requireConnection(connection)
            let snapshot = FilmFlowSnapshot(schema: "ngv.filmflow-snapshot.v1", id: id, resource: FilmFlowHTTP.endpoint,
                startedAt: started, finishedAt: Date(), project: selected, noActiveScript: detail.activeScriptVersion == nil,
                responses: responses, images: images.values.sorted { $0.id < $1.id }, missingImages: missing.sorted { $0.pointer < $1.pointer })
            let bytes = try FilmFlowSnapshot.encode(snapshot)
            try bytes.write(to: directory.appendingPathComponent("snapshot.v1.json"), options: .atomic)
            let hash = FileDigest.sha256(of: bytes)
            _ = try FilmFlowSnapshot.verify(directory: directory, expectedSHA256: hash)
            return .init(snapshot: snapshot, directory: directory, manifestSHA256: hash)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func response(_ name: String, project: String?) async throws -> Data {
        try Task.checkCancellation()
        let arguments: [String: Value] = project.map { ["projectId": .string($0)] } ?? [:]
        do {
            let text = try await cancellable { try await self.client.readTextTool(name: name, arguments: arguments) }
            try await requireConnection(connection)
            return Data(text.utf8)
        } catch let error as MCPProviderClient.ClientError {
            try Task.checkCancellation()
            if case .toolFailed(let text) = error, text.hasSuffix("(NO_ACTIVE_SCRIPT_VERSION)") {
                throw FilmFlowFailure.message("This FilmFlow project has no active script. Refresh projects to capture project and entity material only.")
            }
            throw FilmFlowFailure.message("FilmFlow could not read \(name). Reconnect or refresh projects.")
        }
    }

    private func cancellable<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            do {
                let result = try await work()
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: { [client] in
            Task { await client.disconnect() }
        }
    }

    private func changed() -> FilmFlowFailure {
        .message("FilmFlow changed during capture. Refresh projects and capture again. No snapshot was accepted.")
    }
}
