import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing

@Suite("Managed bpy storage identity")
struct BpyStoragePathsTests {
    @Test(arguments: [false, true])
    func symlinksCannotSelectAnotherDirectory(ancestor: Bool) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let pointer = try #require(realpath(temporary.path, nil))
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer))
        let target = root.appendingPathComponent("target")
        let child = target.appendingPathComponent("child")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let opened = try BpyStoragePaths.openDirectory(child)
        defer { Darwin.close(opened) }
        #expect(try BpyStoragePaths.identity(opened).inode > 0)
        #expect(throws: POSIXError(.ELOOP)) {
            let unexpected = try BpyStoragePaths.openDirectory(ancestor ? alias.appendingPathComponent("child") : alias)
            Darwin.close(unexpected)
        }
    }

    @Test(arguments: [false, true])
    func resolvedLocationCannotSubstituteForTheLeasedMount(nonFile: Bool) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let pointer = try #require(realpath(temporary.path, nil))
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer))
        let sibling = root.appendingPathComponent("sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let bookmark = try root.bookmarkData(options: [.withoutImplicitSecurityScope])
        let resolved: URL
        if nonFile { resolved = try #require(URL(string: "https://example.invalid" + root.path)) }
        else { resolved = sibling }
        try #require(BpyStoragePaths.bookmarkVolumeMatch(bookmark, mount: resolved) == "equal")
        let lease = BpyStorageLease(id: UUID(), mountPath: root.path, device: 1,
                                    capacityBytes: 1, bookmark: bookmark)
        #expect(throws: CocoaError(.fileReadNoPermission)) {
            let unexpected = try BpyStoragePaths.validateResolvedMount(lease, resolved: resolved, maximumBytes: 1)
            Darwin.close(unexpected)
        }
    }

    @Test func absentBookmarkIdentityCannotAuthorizeAMatchingPath() throws {
        let resolved = URL(fileURLWithPath: "/private/mount")
        let lease = BpyStorageLease(id: UUID(), mountPath: resolved.path, device: 1,
                                    capacityBytes: 1, bookmark: Data([1]))
        #expect(throws: CocoaError(.fileReadNoPermission)) {
            let unexpected = try BpyStoragePaths.validateResolvedMount(lease, resolved: resolved, maximumBytes: 1)
            Darwin.close(unexpected)
        }
    }
}
