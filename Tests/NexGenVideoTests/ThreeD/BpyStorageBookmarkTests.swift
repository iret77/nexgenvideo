import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Managed bpy storage bookmarks")
struct BpyStorageBookmarkTests {
    private enum Failure: Error, Equatable { case injected }
    private let mount = URL(fileURLWithPath: "/private/fixture/mount", isDirectory: true)
    private let original = Data([1, 2, 3])
    private let refreshed = Data([4, 5, 6])

    @Test func freshBookmarkKeepsOriginalBytesAndDoesNotRecreate() throws {
        var made: [URL] = []
        var resolved: [Data] = []
        let result = try BpyRuntimeVolume.verifiedBookmark(for: mount, make: {
            made.append($0)
            return original
        }, resolve: {
            resolved.append($0)
            return (mount, false)
        })
        #expect(result == original)
        #expect(made == [mount])
        #expect(resolved == [original])
    }

    @Test func staleBookmarkRecreatesFromResolvedURLAndReturnsOnlyVerifiedBytes() throws {
        let resolvedURL = URL(fileURLWithPath: mount.path)
        var made: [URL] = []
        var resolved: [Data] = []
        var observations: [Data] = []
        var attempts: [Int] = []
        var staleValues: [Bool] = []
        let result = try BpyRuntimeVolume.verifiedBookmark(for: mount, make: {
            made.append($0)
            return made.count == 1 ? original : refreshed
        }, resolve: {
            resolved.append($0)
            return (resolvedURL, $0 == original)
        }, observed: { bytes, url, stale, attempt in
            #expect(url == resolvedURL)
            observations.append(bytes)
            attempts.append(attempt)
            staleValues.append(stale)
        })
        #expect(result == refreshed)
        #expect(made == [mount, resolvedURL])
        #expect(resolved == [original, refreshed])
        #expect(observations == [original, refreshed])
        #expect(attempts == [1, 2])
        #expect(staleValues == [true, false])
    }

    @Test func persistentlyStaleBookmarkStopsAfterOneRefresh() {
        var makes = 0
        var resolves = 0
        var observed: [Int] = []
        #expect(throws: BpyRuntimeError.self) {
            _ = try BpyRuntimeVolume.verifiedBookmark(for: mount, make: { _ in
                makes += 1
                return makes == 1 ? original : refreshed
            }, resolve: { _ in
                resolves += 1
                guard resolves <= 2 else { throw Failure.injected }
                return (mount, true)
            }, observed: { _, _, _, attempt in observed.append(attempt) })
        }
        #expect(makes == 2)
        #expect(resolves == 2)
        #expect(observed == [1, 2])
    }

    @Test(arguments: [1, 2])
    func changedResolutionCannotBecomeStoredBookmark(attempt: Int) {
        var makes = 0
        var resolves = 0
        var observed: [Int] = []
        #expect(throws: BpyRuntimeError.self) {
            _ = try BpyRuntimeVolume.verifiedBookmark(for: mount, make: { _ in
                makes += 1
                return makes == 1 ? original : refreshed
            }, resolve: { _ in
                resolves += 1
                let target = resolves == attempt ? mount.appendingPathComponent("other") : mount
                return (target, resolves == 1)
            }, observed: { _, _, _, attempt in observed.append(attempt) })
        }
        #expect(makes == attempt)
        #expect(resolves == attempt)
        #expect(observed == Array(1...attempt))
    }

    @Test func nonFileResolutionWithMatchingPathIsRejected() throws {
        let other = try #require(URL(string: "https://example.invalid" + mount.path))
        #expect(other.path == mount.path)
        #expect(throws: BpyRuntimeError.self) {
            _ = try BpyRuntimeVolume.verifiedBookmark(for: mount, make: { _ in original },
                                                     resolve: { _ in (other, false) })
        }
    }

    @Test(arguments: [1, 2, 3, 4])
    func creationAndResolutionErrorsPropagateWithoutFurtherWork(failureStep: Int) {
        var steps = 0
        #expect(throws: Failure.injected) {
            _ = try BpyRuntimeVolume.verifiedBookmark(for: mount, make: { _ in
                steps += 1
                if steps == failureStep { throw Failure.injected }
                return steps == 1 ? original : refreshed
            }, resolve: { _ in
                steps += 1
                if steps == failureStep { throw Failure.injected }
                return (mount, true)
            })
        }
        #expect(steps == failureStep)
    }

    @Test func realFoundationBookmarkResolvesFreshAtTheExactDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawPath = realpath(directory.path, nil)
        let path = try #require(rawPath)
        defer { free(path) }
        let canonical = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        let data = try BpyRuntimeVolume.verifiedBookmark(for: canonical)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: data,
                               options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        #expect(!stale)
        #expect(resolved.isFileURL)
        #expect(resolved.path == canonical.path)
    }
}
