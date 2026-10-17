import Foundation
import NexGenEngine

struct ReviewReelSoundtrack: Codable, Sendable {
    struct Source: Codable, Sendable, Equatable {
        let mediaID: String
        let path: String
        let sha256: String
        var isExternal: Bool? = nil

        func resolve(dataRoot: URL) throws -> URL {
            guard isExternal == true else {
                return try ProjectLocalFile.requireHash(sha256, at: path, dataRoot: dataRoot)
            }
            do {
                let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                guard path.hasPrefix("/"), url.path == path,
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                      try FileDigest.sha256(of: url) == sha256 else {
                    throw ToolError("The external soundtrack identity changed.")
                }
                return url
            } catch {
                throw ToolError("The externally linked soundtrack is unavailable or changed. Restore its source or review the current cut again.")
            }
        }
    }

    let schema: String
    let fps: Int
    let tracks: [Track]
    let sources: [Source]

    static func capture(timeline: Timeline?, resolver: MediaResolver?, fps: Int, dataRoot: URL) throws -> Self {
        guard timeline == nil || timeline?.fps == fps else {
            throw ToolError("Sequence review requires the assembled timeline and sources to use the same frame rate.")
        }
        let tracks = timeline?.tracks.filter { $0.type == .audio } ?? []
        let references = Set(tracks.flatMap(\.clips).map(\.mediaRef)).sorted()
        let home = FrameInventory.projectHome(of: dataRoot).standardizedFileURL.resolvingSymlinksInPath()
        let sources = try references.map { id -> Source in
            guard let resolver, let entry = resolver.entry(for: id), let resolved = resolver.resolveURL(for: id) else {
                throw ToolError("Restore the project's audio source before sequence review.")
            }
            let url = resolved.standardizedFileURL.resolvingSymlinksInPath()
            if case .external = entry.source {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw ToolError("Restore the project's audio source before sequence review.")
                }
                return Source(mediaID: id, path: url.path, sha256: try FileDigest.sha256(of: url), isExternal: true)
            }
            guard url.path.hasPrefix(home.path + "/") else {
                throw ToolError("The reviewed audio must resolve inside its project.")
            }
            let path = String(url.path.dropFirst(home.path.count + 1))
            let local = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
            guard local.standardizedFileURL.resolvingSymlinksInPath() == url else {
                throw ToolError("The reviewed audio must resolve to its exact project-local source.")
            }
            return Source(mediaID: id, path: path, sha256: try FileDigest.sha256(of: local))
        }
        return Self(schema: "review-reel-audio/v1", fps: fps, tracks: tracks, sources: sources)
    }

    func reelID(plan: AssemblyPlanV1) throws -> String {
        var bytes = try PipelineAssemblyStore.canonical(plan)
        bytes.append(try PipelineAssemblyStore.canonical(self))
        return FileDigest.sha256(of: bytes)
    }

    static func path(reelPath: String) -> String {
        String(reelPath.dropLast(4)) + ".audio.v1.json"
    }

    static func requireCurrent(reel: ReviewReelV1, plan: AssemblyPlanV1, dataRoot: URL,
                               timeline: Timeline? = nil, resolver: MediaResolver? = nil) throws {
        guard reel.path.hasSuffix(".mp4") else { throw ToolError("The review reel path is malformed.") }
        let binding: Self
        do {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path(reelPath: reel.path), dataRoot: dataRoot))
            binding = try JSONDecoder().decode(Self.self, from: bytes)
        } catch {
            throw ToolError("This review has no readable soundtrack record. Build a new review reel and record the review again.")
        }
        guard binding.schema == "review-reel-audio/v1", binding.fps == reel.fps,
              reel.path == "reviews/sequence/reels/\(try binding.reelID(plan: plan)).mp4",
              Set(binding.sources.map(\.mediaID)) == Set(binding.tracks.flatMap(\.clips).map(\.mediaRef)) else {
            throw ToolError("The review reel is not bound to its current cut and soundtrack.")
        }
        for source in binding.sources {
            _ = try source.resolve(dataRoot: dataRoot)
        }
        if let timeline {
            guard timeline.fps == binding.fps,
                  try PipelineAssemblyStore.canonical(timeline.tracks.filter { $0.type == .audio })
                    == PipelineAssemblyStore.canonical(binding.tracks) else {
                throw ToolError("The soundtrack timing, gain or mute state changed. Review the current cut again.")
            }
            if let resolver {
                let current = try capture(timeline: timeline, resolver: resolver, fps: binding.fps, dataRoot: dataRoot)
                guard current.sources == binding.sources else {
                    throw ToolError("The soundtrack source changed. Review the current cut again.")
                }
            }
        }
    }
}
