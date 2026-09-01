import Foundation
import NexGenEngine

enum PipelineExecutionShotInputStoreError: Error, Sendable, Equatable {
    case invalidDocument
    case shotlistMismatch
    case unsafePath(String)
}

enum PipelineExecutionShotInputStore {
    static let artifactID = "execution-shot-inputs"
    static let artifactRole = "core.execution-shot-inputs"

    struct Loaded: Sendable, Equatable {
        let executionShots: [PipelineExecutionShotInput]
        let data: Data
    }

    struct Snapshot: Sendable {
        fileprivate let data: Data?
    }

    private struct Document: Codable, Sendable, Equatable {
        static let schemaVersion = "execution-shot-inputs/v1"

        let schema: String
        let projectID: String
        let shotlistPath: String
        let shotlistSHA256: String
        let executionShots: [PipelineExecutionShotInput]

        private enum CodingKeys: String, CodingKey {
            case schema
            case projectID = "project_id"
            case shotlistPath = "shotlist_path"
            case shotlistSHA256 = "shotlist_sha256"
            case executionShots = "execution_shots"
        }

        init(
            projectID: String,
            shotlistPath: String,
            shotlistSHA256: String,
            executionShots: [PipelineExecutionShotInput]
        ) {
            schema = Self.schemaVersion
            self.projectID = projectID
            self.shotlistPath = shotlistPath
            self.shotlistSHA256 = shotlistSHA256
            self.executionShots = executionShots
        }
    }

    static func canonicalData(
        executionShots: [PipelineExecutionShotInput],
        shotlist: Shotlist,
        shotlistPath: String,
        shotlistData: Data
    ) throws -> Data {
        try validate(
            executionShots: executionShots,
            shotlist: shotlist,
            shotlistPath: shotlistPath,
            shotlistSHA256: FileDigest.sha256(of: shotlistData)
        )
        return try encode(Document(
            projectID: shotlist.project,
            shotlistPath: shotlistPath,
            shotlistSHA256: FileDigest.sha256(of: shotlistData),
            executionShots: executionShots
        ))
    }

    static func write(_ data: Data, dataRoot: URL) throws {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schema == Document.schemaVersion,
              try encode(document) == data else {
            throw PipelineExecutionShotInputStoreError.invalidDocument
        }
        let url = PipelineLayout.url(PipelineLayout.executionShotInputsFile, in: dataRoot)
        try requireSafe(url: url, dataRoot: dataRoot, allowMissingDirectory: true)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try requireSafe(url: url, dataRoot: dataRoot, allowMissingDirectory: false)
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else {
            throw PipelineExecutionShotInputStoreError.invalidDocument
        }
    }

    static func loadCurrent(dataRoot: URL) throws -> Loaded {
        let url = PipelineLayout.url(PipelineLayout.executionShotInputsFile, in: dataRoot)
        try requireSafe(url: url, dataRoot: dataRoot, allowMissingDirectory: false)
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schema == Document.schemaVersion,
              try encode(document) == data,
              let version = latestShotlistVersion(dataRoot: dataRoot) else {
            throw PipelineExecutionShotInputStoreError.invalidDocument
        }
        let shotlistPath = PipelineLayout.shotlistVersionFile(version)
        let shotlistURL = try ProjectLocalFile.resolve(shotlistPath, dataRoot: dataRoot)
        let shotlistData = try Data(contentsOf: shotlistURL)
        guard let shotlist = try loadShotlist(dataRoot: dataRoot) else {
            throw PipelineExecutionShotInputStoreError.shotlistMismatch
        }
        try validate(
            executionShots: document.executionShots,
            shotlist: shotlist,
            shotlistPath: document.shotlistPath,
            shotlistSHA256: document.shotlistSHA256
        )
        guard document.projectID == shotlist.project,
              document.shotlistPath == shotlistPath,
              document.shotlistSHA256 == FileDigest.sha256(of: shotlistData) else {
            throw PipelineExecutionShotInputStoreError.shotlistMismatch
        }
        return Loaded(executionShots: document.executionShots, data: data)
    }

    static func snapshot(dataRoot: URL) throws -> Snapshot {
        let url = PipelineLayout.url(PipelineLayout.executionShotInputsFile, in: dataRoot)
        try requireSafe(url: url, dataRoot: dataRoot, allowMissingDirectory: true)
        return Snapshot(data: FileManager.default.fileExists(atPath: url.path)
            ? try Data(contentsOf: url)
            : nil)
    }

    static func restore(_ snapshot: Snapshot, dataRoot: URL) throws {
        let url = PipelineLayout.url(PipelineLayout.executionShotInputsFile, in: dataRoot)
        try requireSafe(url: url, dataRoot: dataRoot, allowMissingDirectory: true)
        if let data = snapshot.data {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func validate(
        executionShots: [PipelineExecutionShotInput],
        shotlist: Shotlist,
        shotlistPath: String,
        shotlistSHA256: String
    ) throws {
        guard !shotlistPath.isEmpty,
              !shotlistSHA256.isEmpty,
              executionShots.count == shotlist.shots.count,
              zip(executionShots, shotlist.shots).allSatisfy({ input, shot in
                  input.id == shot.id && matches(input.sourceMode, shot.sourceMode)
              }) else {
            throw PipelineExecutionShotInputStoreError.shotlistMismatch
        }
        for (input, shot) in zip(executionShots, shotlist.shots) {
            try input.validate(timedBeatMaximumSeconds: shot.durationS)
        }
    }

    private static func matches(
        _ executionMode: ExecutionSourceModeV1,
        _ sourceMode: SourceMode
    ) -> Bool {
        switch (executionMode, sourceMode) {
        case (.generated, .generated), (.imported, .imported),
             (.aiEnhanced, .aiEnhanced):
            return true
        default:
            return false
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func requireSafe(
        url: URL,
        dataRoot: URL,
        allowMissingDirectory: Bool
    ) throws {
        let root = dataRoot.standardizedFileURL
        let target = url.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/"),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: root.path)) == nil else {
            throw PipelineExecutionShotInputStoreError.unsafePath(target.path)
        }
        var current = root
        for component in target.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw PipelineExecutionShotInputStoreError.unsafePath(target.path)
            }
        }
        let directory = target.deletingLastPathComponent()
        if !allowMissingDirectory || FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw PipelineExecutionShotInputStoreError.unsafePath(directory.path)
            }
        }
    }
}
