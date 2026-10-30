import BpyRuntimeProtocol
import Foundation

nonisolated enum BpyHostConfiguration {
    static let maximumBytes: UInt64 = 1_024 * 1_024

    struct Context {
        let mode: BpyLaunchMode
        let identity: BpyAdmissionIdentity
        let limits: BpyRuntimeLimits
        let workerMount: String
        let dataMount: String
        let root: String
        let sitePackages: String
        let readPaths: Set<String>
        let sourceSHA256: String?
        let fingerprint: String?
        let diagnosticDeniedPaths: [String]
    }

    private struct Geometry: Codable, Equatable {
        let objects: Int
        let vertices: Int
        let polygons: Int
        let renderWidth: Int
        let renderHeight: Int
        let renderPixels: Int

        init(_ limits: BpyRuntimeLimits) {
            objects = limits.objects; vertices = limits.vertices; polygons = limits.polygons
            renderWidth = limits.renderWidth; renderHeight = limits.renderHeight; renderPixels = limits.renderPixels
        }
    }

    private struct Configuration: Codable {
        let sitePackages: String
        let memoryPolicy: String
        let outputBytes: UInt64
        let cpuSeconds: Int
        let manifest: String?
        let jobID: String?
        let sessionRoot: String?
        let workerRoot: String?
        let sourcePath: String?
        let inputDirectory: String?
        let outputDirectory: String?
        let limits: Geometry?
        let confirmedScene: String?
        let fingerprint: String?
        let scenePath: String?
        let diagnosticDeniedPaths: [String]?
        var hostSourceSHA256: String?
    }

    static func freeze(_ data: Data, context: Context) throws -> Data {
        guard UInt64(data.count) <= maximumBytes else { throw BpyRuntimeError.invalidInput("The worker configuration is too large.") }
        if context.mode == .boundary {
            guard data == Data("{}".utf8) else { throw SpatialSceneError.changed }
            return data
        }
        var config = try JSONDecoder().decode(Configuration.self, from: data)
        let session = context.dataMount + "/" + context.identity.transport.uuidString
        let workerSession = context.workerMount + "/" + context.identity.transport.uuidString
        guard config.sitePackages == context.sitePackages, config.memoryPolicy == "system-pressure-v1",
              config.outputBytes == context.limits.outputBytes,
              config.cpuSeconds == max(2, Int(context.identity.runningTimeout) + 1), config.hostSourceSHA256 == nil else {
            throw SpatialSceneError.changed
        }
        switch context.mode {
        case .probe:
            guard config.manifest == context.root + "/manifest.json", config.jobID == nil,
                  config.scenePath == nil, config.sourcePath == nil, config.confirmedScene == nil,
                  config.inputDirectory == nil, config.outputDirectory == nil, config.limits == nil else { throw SpatialSceneError.changed }
        case .job:
            guard let job = context.identity.job, let hash = context.sourceSHA256,
                  config.jobID == job.uuidString, config.sessionRoot == session, config.workerRoot == workerSession,
                  config.sourcePath == session + "/jobs/" + job.uuidString + "/source.py",
                  config.inputDirectory == session + "/jobs/" + job.uuidString + "/inputs",
                  config.outputDirectory == context.root + "/outputs", config.limits == Geometry(context.limits),
                  config.manifest == nil, config.scenePath == nil else { throw SpatialSceneError.changed }
            if let checkpoint = config.confirmedScene {
                guard checkpoint == session + "/jobs/" + job.uuidString + "/bootstrap/confirmed.blend",
                      context.readPaths.contains(checkpoint) else { throw SpatialSceneError.changed }
            }
            config.hostSourceSHA256 = hash
        case .verify:
            guard let job = context.identity.job, let fingerprint = context.fingerprint,
                  config.jobID == job.uuidString, config.fingerprint == fingerprint, config.sessionRoot == session,
                  config.manifest == context.root + "/manifest.json", config.limits == Geometry(context.limits),
                  config.sourcePath == nil, config.confirmedScene == nil, config.inputDirectory == nil,
                  config.outputDirectory == nil,
                  config.scenePath == workerSession + "/jobs/" + job.uuidString + "/worker/outputs/scene.blend",
                  context.readPaths.contains(config.scenePath ?? ""),
                  (config.diagnosticDeniedPaths ?? []) == context.diagnosticDeniedPaths else { throw SpatialSceneError.changed }
        case .autoexecPositive:
            guard let job = context.identity.job, context.identity.diagnosticAutoexec,
                  config.jobID == job.uuidString, config.manifest == context.root + "/manifest.json",
                  config.scenePath == context.root + "/positive-control.blend", config.sourcePath == nil,
                  config.confirmedScene == nil, config.inputDirectory == nil, config.outputDirectory == nil else { throw SpatialSceneError.changed }
        case .boundary: throw SpatialSceneError.changed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(config)
    }
}
