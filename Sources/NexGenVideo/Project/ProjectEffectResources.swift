import Foundation
import NexGenEngine

enum ProjectEffectResources {
    static let directory = "resources/luts"

    struct Problem: Identifiable, Sendable, Equatable {
        let id: String
        let clipID: String
        let effectID: String
        let path: String
        let name: String
        let message: String
    }

    struct Binding: Sendable, Equatable {
        let path: String
        let url: URL
        let sha256: String
        let byteCount: Int
    }

    static func isPortable(_ path: String) -> Bool {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0] == "resources", pieces[1] == "luts",
              pieces[2].hasSuffix(".cube") else { return false }
        let hash = pieces[2].dropLast(5)
        return hash.count == 64 && hash.allSatisfy { $0.isASCII && (("0"..."9").contains($0) || ("a"..."f").contains($0)) }
    }

    static func url(for path: String, projectRoot: URL) throws -> URL {
        guard isPortable(path) else { throw LUTStoreError.invalid(path) }
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath() == url, url.path.hasPrefix(root.path + "/") else { throw LUTStoreError.invalid(path) }
        return url
    }

    static func capture(timeline: Timeline, projectRoot: URL?) throws -> [Binding] {
        try capture(timeline: timeline, resolver: MediaResolver(manifest: { MediaManifest() }, projectURL: { projectRoot }))
    }

    static func capture(timeline: Timeline, resolver: MediaResolver) throws -> [Binding] {
        var bindings: [String: Binding] = [:]
        for track in timeline.tracks {
            for clip in track.clips {
                for effect in clip.effects ?? [] {
                    guard let key = EffectRegistry.descriptor(id: effect.type)?.resourceKey,
                          let path = effect.params[key]?.string, !path.isEmpty else { continue }
                    guard let resource = resolver.effectResourceURL(for: path) else { throw LUTStoreError.noFile(path) }
                    let bytes = try LUTLoader.validatedBytes(at: resource)
                    let hash = FileDigest.sha256(of: bytes)
                    if isPortable(path) { try LUTLoader.register(bytes, path: path) }
                    bindings[path] = Binding(path: path, url: resource, sha256: hash, byteCount: bytes.count)
                }
            }
        }
        return bindings.values.sorted { $0.path < $1.path }
    }

    static func requireCurrent(_ bindings: [Binding]) throws {
        for binding in bindings {
            let bytes = try LUTLoader.validatedBytes(at: binding.url)
            guard bytes.count == binding.byteCount, FileDigest.sha256(of: bytes) == binding.sha256 else { throw LUTStoreError.invalid(binding.path) }
            if isPortable(binding.path) { try LUTLoader.register(bytes, path: binding.path) }
        }
    }

    static func open(timeline: Timeline, projectRoot: URL, importLegacy: Bool = true) throws -> (timeline: Timeline, problems: [Problem]) {
        var result = timeline
        var problems: [Problem] = []
        for track in result.tracks.indices {
            for clip in result.tracks[track].clips.indices {
                guard var effects = result.tracks[track].clips[clip].effects else { continue }
                for index in effects.indices {
                    guard let key = EffectRegistry.descriptor(id: effects[index].type)?.resourceKey,
                          let path = effects[index].params[key]?.string, !path.isEmpty else { continue }
                    guard isPortable(path) || (path as NSString).isAbsolutePath else { throw LUTStoreError.invalid(path) }
                    do {
                        if !importLegacy, !isPortable(path) {
                            _ = try LUTLoader.validatedBytes(at: URL(fileURLWithPath: path))
                        } else {
                            let stored = try LUTLoader.store(path: path, projectRoot: projectRoot)
                            effects[index].params[key]?.string = stored
                            if effects[index].params["name"]?.string == nil, !isPortable(path) {
                                effects[index].params["name"] = EffectParam(string: URL(fileURLWithPath: path).lastPathComponent)
                            }
                        }
                    } catch {
                        let name = effects[index].params["name"]?.string ?? (isPortable(path) ? "Project LUT" : URL(fileURLWithPath: path).lastPathComponent)
                        problems.append(Problem(id: result.tracks[track].clips[clip].id + ":" + effects[index].id,
                            clipID: result.tracks[track].clips[clip].id, effectID: effects[index].id, path: path, name: name,
                            message: "The LUT ‘\(name)’ is offline, unreadable, or its stored bytes changed. Relink or remove it before saving or exporting."))
                    }
                }
                result.tracks[track].clips[clip].effects = effects
            }
        }
        return (result, problems)
    }

    static func renderTimeline(_ timeline: Timeline, bindings: [Binding]) throws -> Timeline {
        var resources: [String: String] = [:]
        for binding in bindings {
            let bytes = try LUTLoader.validatedBytes(at: binding.url)
            guard bytes.count == binding.byteCount, FileDigest.sha256(of: bytes) == binding.sha256 else {
                throw LUTStoreError.invalid(binding.path)
            }
            let key = directory + "/" + binding.sha256 + ".cube"
            try LUTLoader.register(bytes, path: key)
            resources[binding.path] = key
        }
        var result = timeline
        for track in result.tracks.indices {
            for clip in result.tracks[track].clips.indices {
                guard var effects = result.tracks[track].clips[clip].effects else { continue }
                for index in effects.indices {
                    guard let key = EffectRegistry.descriptor(id: effects[index].type)?.resourceKey,
                          let path = effects[index].params[key]?.string, !path.isEmpty else { continue }
                    guard let resource = resources[path] else { throw LUTStoreError.noFile(path) }
                    effects[index].params[key]?.string = resource
                }
                result.tracks[track].clips[clip].effects = effects
            }
        }
        return result
    }

    static func portable(_ timeline: Timeline, projectRoot: URL) throws -> Timeline {
        var result = timeline
        for track in result.tracks.indices {
            for clip in result.tracks[track].clips.indices {
                guard var effects = result.tracks[track].clips[clip].effects else { continue }
                for index in effects.indices {
                    guard let key = EffectRegistry.descriptor(id: effects[index].type)?.resourceKey,
                          let path = effects[index].params[key]?.string, !path.isEmpty else { continue }
                    let stored = try LUTLoader.store(path: path, projectRoot: projectRoot)
                    effects[index].params[key]?.string = stored
                    if effects[index].params["name"]?.string == nil, !isPortable(path) {
                        effects[index].params["name"] = EffectParam(string: URL(fileURLWithPath: path).lastPathComponent)
                    }
                }
                result.tracks[track].clips[clip].effects = effects
            }
        }
        return result
    }
}
