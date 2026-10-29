import Darwin
import Foundation
import NexGenEngine

enum PipelineNativeTakeSourceFence {
    struct Snapshot: Sendable {
        let files: [URL: [Int64]]
        func requireUnchanged() throws {
            for (url, expected) in files {
                guard try PipelineNativeTakeSourceFence.stamp(url) == expected else { throw PipelineNativeTakeSourceFence.changed() }
            }
        }
    }

    static func capture(_ urls: [URL]) throws -> Snapshot {
        var files: [URL: [Int64]] = [:]
        for url in urls { files[url] = try stamp(url) }
        return Snapshot(files: files)
    }

    private static func stamp(_ url: URL) throws -> [Int64] {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw changed() }
        return [Int64(value.st_dev), Int64(bitPattern: value.st_ino), value.st_size,
            Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
            Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
    }

    private static func changed() -> GateBlocked {
        GateBlocked("The take's generation receipt or original media changed while its selection was being prepared.")
    }
}
