import AVFoundation
import Darwin
import Foundation

enum FilmReviewExportDiagnostic {
    static let enabled = ProcessInfo.processInfo.environment["NGV_FILM_REVIEW_EXPORT_DIAGNOSTIC"] == "1"
        && ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        && ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] == "iret77/nexgenvideo"

    private struct Instance {
        var alive = true
        var started = 0
        var frame = 0
        var error = 0
        var cancelled = 0
        var dropped = 0
        var pending = Set<ObjectIdentifier>()
        var lastStarted = "none"
        var lastFinished = "none"
    }

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        let outputLock = NSLock()
        var nextID = 0
        var ids: [ObjectIdentifier: Int] = [:]
        var instances: [Int: Instance] = [:]
        var states: [String: String] = [:]
    }

    private static let store = Store()

    static func emit(_ stage: String, exportID: String, fields: [String: Any] = [:]) {
        guard enabled else { return }
        var record = fields
        record["stage"] = stage
        record["exportID"] = exportID
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        store.outputLock.withLock {
            FileHandle.standardError.write(Data("[film-review-export] ".utf8) + bytes + Data([10]))
        }
    }

    static func time(_ value: CMTime) -> String {
        value.isNumeric ? "\(value.value)/\(value.timescale)@\(value.epoch)" : "non-numeric"
    }

    static func range(_ value: CMTimeRange) -> [String: String] {
        ["start": time(value.start), "duration": time(value.duration)]
    }

    static func created(_ owner: AnyObject) {
        guard enabled else { return }
        let id = store.lock.withLock {
            store.nextID += 1
            store.ids[ObjectIdentifier(owner)] = store.nextID
            store.instances[store.nextID] = Instance()
            return store.nextID
        }
        emit("compositor.created", exportID: "unbound", fields: ["instance": id])
    }

    static func identity(_ owner: AnyObject) -> Int {
        guard enabled else { return 0 }
        return store.lock.withLock { store.ids[ObjectIdentifier(owner)] ?? 0 }
    }

    static func destroyed(_ owner: AnyObject, pendingCount: Int) {
        guard enabled else { return }
        let id = store.lock.withLock {
            let id = store.ids.removeValue(forKey: ObjectIdentifier(owner)) ?? 0
            store.instances[id]?.alive = false
            return id
        }
        emit("compositor.destroyed", exportID: "unbound", fields: ["instance": id, "ownerPending": pendingCount])
    }

    static func request(_ kind: String, instance: Int, request: AVAsynchronousVideoCompositionRequest) {
        guard enabled else { return }
        store.lock.withLock {
            guard var value = store.instances[instance] else { return }
            let key = ObjectIdentifier(request)
            if kind == "started" {
                value.started += 1
                value.pending.insert(key)
                value.lastStarted = time(request.compositionTime)
            } else if kind == "dropped" {
                value.dropped += 1
            } else {
                value.pending.remove(key)
                value.lastFinished = time(request.compositionTime)
                switch kind {
                case "frame": value.frame += 1
                case "error": value.error += 1
                case "cancelled": value.cancelled += 1
                default: break
                }
            }
            store.instances[instance] = value
        }
    }

    static func state(_ state: AVAssetExportSession.State, exportID: String) {
        guard enabled else { return }
        let value: String
        switch state {
        case .pending: value = "pending"
        case .waiting: value = "waiting"
        case .exporting(let progress): value = "exporting:\(progress.fractionCompleted)"
        @unknown default: value = "unknown"
        }
        store.lock.withLock { store.states[exportID] = value }
    }

    @MainActor
    static func heartbeat(_ session: AVAssetExportSession, output: URL) {
        guard enabled else { return }
        let instance = session.customVideoCompositor.map { identity($0 as AnyObject) } ?? 0
        let snapshot: [String: Any] = store.lock.withLock {
            let ledger: [[String: Any]] = store.instances.keys.sorted().compactMap { id in
                guard let v = store.instances[id] else { return nil }
                return ["instance": id, "alive": v.alive, "started": v.started, "frame": v.frame,
                        "error": v.error, "cancelled": v.cancelled, "dropped": v.dropped,
                        "pending": v.pending.count, "lastStarted": v.lastStarted, "lastFinished": v.lastFinished]
            }
            return ["nativeState": store.states[output.lastPathComponent] ?? "not-observed",
                    "compositor": instance, "ledger": ledger]
        }
        var fields = snapshot
        var info = stat()
        fields["outputBytes"] = lstat(output.path, &info) == 0 ? info.st_size : -1
        emit("heartbeat", exportID: output.lastPathComponent, fields: fields)
    }

    @MainActor
    static func prepared(_ result: CompositionResult, session: AVAssetExportSession,
                         timeline: Timeline, resolver: MediaResolver, output: URL) async {
        guard enabled else { return }
        emit("metadata.begin", exportID: output.lastPathComponent)
        do {
            let duration = try await result.composition.load(.duration)
            let tracks = try await result.composition.load(.tracks)
            var trackRecords: [[String: Any]] = []
            for track in tracks {
                var row: [String: Any] = ["id": track.trackID, "type": track.mediaType.rawValue,
                                          "range": range(try await track.load(.timeRange))]
                if let composition = track as? AVCompositionTrack {
                    row["segments"] = composition.segments.map {
                        ["empty": $0.isEmpty, "source": range($0.timeMapping.source), "target": range($0.timeMapping.target)] as [String: Any]
                    }
                }
                trackRecords.append(row)
            }
            let sources: [[String: Any]] = Set(timeline.tracks.flatMap(\.clips).map(\.mediaRef)).sorted().compactMap { ref in
                guard let url = resolver.resolveURL(for: ref) else { return ["mediaID": ref, "missing": true] }
                var info = stat()
                guard lstat(url.path, &info) == 0 else { return ["mediaID": ref, "statFailed": true] }
                return ["mediaID": ref, "name": url.lastPathComponent, "inode": info.st_ino,
                        "device": info.st_dev, "bytes": info.st_size]
            }
            var fields: [String: Any] = ["duration": time(duration), "range": range(session.timeRange),
                                        "tracks": trackRecords, "sources": sources,
                                        "frameDuration": time(result.videoComposition.frameDuration),
                                        "width": result.videoComposition.renderSize.width,
                                        "height": result.videoComposition.renderSize.height,
                                        "audioInputs": result.audioMix.inputParameters.count,
                                        "instructions": result.videoComposition.instructions.count]
            fields["instructionRanges"] = result.videoComposition.instructions.map { range($0.timeRange) }
            emit("session.prepared", exportID: output.lastPathComponent, fields: fields)
        } catch {
            emit("metadata.threw", exportID: output.lastPathComponent,
                 fields: ["domain": (error as NSError).domain, "code": (error as NSError).code])
        }
    }
}
