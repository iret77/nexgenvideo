import Foundation
import Testing
@testable import NexGenVideo

@Suite("Checked Settings index removal")
struct StorageCheckedRemovalTests {
    @Test func permissionFailureIsReportedAndRetrySucceeds() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("checked-index-" + UUID().uuidString)
        let parent = root.appendingPathComponent("protected")
        let index = parent.appendingPathComponent("index")
        let sibling = parent.appendingPathComponent("keep.bin")
        try manager.createDirectory(at: index, withIntermediateDirectories: true)
        let retained = Data("outside the selected index".utf8)
        try retained.write(to: sibling)
        try Data("derived data".utf8).write(to: index.appendingPathComponent("sample.embed"))
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? manager.removeItem(at: root)
        }
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        #expect(throws: (any Error).self) { try EmbeddingStore.clearAllChecked(at: index) }
        #expect(manager.fileExists(atPath: index.path))
        #expect(try Data(contentsOf: sibling) == retained)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try EmbeddingStore.clearAllChecked(at: index)
        #expect(!manager.fileExists(atPath: index.path))
        #expect(try Data(contentsOf: sibling) == retained)
        try EmbeddingStore.clearAllChecked(at: index)
    }
}
