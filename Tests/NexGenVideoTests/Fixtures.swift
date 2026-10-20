import Darwin
import Foundation
@testable import NexGenVideo

private func recordTestProcessExitDiagnostic() {
    guard let directory = ProcessInfo.processInfo.environment["NGV_SWIFT_TEST_PROCESS_EVIDENCE"] else { return }
    let row: [String: Any] = ["event": "atexit-callback", "pid": getpid(), "parentPID": getppid(),
        "executable": CommandLine.arguments.first ?? "", "uptime": ProcessInfo.processInfo.systemUptime,
        "stack": Thread.callStackSymbols]
    let path = URL(fileURLWithPath: directory).appendingPathComponent("test-process-\(getpid())-atexit.json")
    do { try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]).write(to: path) }
    catch { FileHandle.standardError.write(Data("[swift-test-process] atexit capture unavailable: \(error)\n".utf8)) }
}

enum Fixtures {
    private static let processExitDiagnostic: Void = {
        guard ProcessInfo.processInfo.environment["NGV_SWIFT_TEST_PROCESS_EVIDENCE"] != nil else { return }
        let result = atexit(recordTestProcessExitDiagnostic)
        let row: [String: Any] = ["event": "atexit-registration", "pid": getpid(), "parentPID": getppid(),
            "result": result, "executable": CommandLine.arguments.first ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data("[swift-test-process] \(line)\n".utf8))
        }
    }()

    static func installProcessExitDiagnostic() { _ = processExitDiagnostic }

    static func clip(
        id: String = UUID().uuidString,
        mediaRef: String = "media-1",
        mediaType: ClipType = .video,
        start: Int,
        duration: Int,
        trimStart: Int = 0,
        trimEnd: Int = 0,
        speed: Double = 1.0,
        volume: Double = 1.0
    ) -> Clip {
        installProcessExitDiagnostic()
        var c = Clip(mediaRef: mediaRef, startFrame: start, durationFrames: duration)
        c.id = id
        c.mediaType = mediaType
        c.sourceClipType = mediaType
        c.trimStartFrame = trimStart
        c.trimEndFrame = trimEnd
        c.speed = speed
        c.volume = volume
        return c
    }

    static func videoTrack(id: String = UUID().uuidString, clips: [Clip] = []) -> Track {
        installProcessExitDiagnostic()
        var t = Track(type: .video, clips: clips)
        t.id = id
        return t
    }

    static func audioTrack(id: String = UUID().uuidString, clips: [Clip] = []) -> Track {
        installProcessExitDiagnostic()
        var t = Track(type: .audio, clips: clips)
        t.id = id
        return t
    }

    static func timeline(fps: Int = 30, tracks: [Track] = []) -> Timeline {
        installProcessExitDiagnostic()
        var t = Timeline()
        t.fps = fps
        t.tracks = tracks
        return t
    }

    @discardableResult
    static func prepareProjectPackage(
        at url: URL,
        timeline: Timeline = Timeline()
    ) throws -> URL {
        installProcessExitDiagnostic()
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(timeline).write(
            to: url.appendingPathComponent(Project.timelineFilename)
        )
        try JSONEncoder().encode(MediaManifest()).write(
            to: url.appendingPathComponent(Project.manifestFilename)
        )
        try JSONEncoder().encode(GenerationLog()).write(
            to: url.appendingPathComponent(Project.generationLogFilename)
        )
        _ = try ProjectIdentity.uuid(for: url)
        return url
    }
}
