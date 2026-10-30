import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing
@testable import NexGenVideo

struct BpyHostStagingTests {
    @Test func recoveryRemovesLargeDeadNamespacesAndPreservesForeignBaseFiles() throws {
        try withBase { base in
            let prior = BpyHostStaging(base: base)
            let directory = try prior.directory("frames"), namespace = directory.deletingLastPathComponent()
            for index in 0..<10_000 {
                try Data([UInt8(truncatingIfNeeded: index)]).write(to: directory.appendingPathComponent("\(index).png"))
            }
            let foreign = base.appendingPathComponent(".DS_Store"), bytes = Data("foreign".utf8)
            try bytes.write(to: foreign)
            try changeRecord(namespace) { $0["boot"] = try differentBoot().uuidString }
            let current = BpyHostStaging(base: base)
            _ = try current.directory("next")
            #expect(!FileManager.default.fileExists(atPath: namespace.path))
            #expect(try Data(contentsOf: foreign) == bytes)
            _ = try current.directory("again")
        }
    }

    @Test func newHostRecoversADeadBootNamespaceBeforeMakingItsOwnDirectory() throws {
        try withBase { base in
            let prior = BpyHostStaging(base: base)
            let media = try prior.directory("media-fixture")
            try Data("unpublished".utf8).write(to: media.appendingPathComponent("clay.mov"))
            let namespace = media.deletingLastPathComponent()
            try changeRecord(namespace) { $0["boot"] = try differentBoot().uuidString }
            let current = BpyHostStaging(base: base)
            let next = try current.directory("session-fixture")
            #expect(!FileManager.default.fileExists(atPath: namespace.path))
            #expect(FileManager.default.fileExists(atPath: next.path))
        }
    }

    @Test func liveOwnerNamespaceAndBorrowedBytesSurviveAnotherHostStarting() throws {
        try withBase { base in
            let first = BpyHostStaging(base: base)
            let directory = try first.directory("media-fixture")
            let bytes = Data("still-live".utf8), url = directory.appendingPathComponent("clay.mov")
            try bytes.write(to: url)
            _ = try BpyHostStaging(base: base).directory("session-other")
            #expect(try Data(contentsOf: url) == bytes)
            #expect(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("owner.json").path))
        }
    }

    @Test func mismatchedNamespaceIdentityIsRetainedAndRefusesAdmission() throws {
        try withBase { base in
            let prior = BpyHostStaging(base: base)
            let directory = try prior.directory("media-fixture")
            let url = directory.appendingPathComponent("clay.mov"), bytes = Data("retained".utf8)
            try bytes.write(to: url)
            try changeRecord(directory.deletingLastPathComponent()) { record in
                record["inode"] = (record["inode"] as! NSNumber).uint64Value + 1
                record["boot"] = try differentBoot().uuidString
            }
            #expect(throws: (any Error).self) { try BpyHostStaging(base: base).prepare() }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func recoveryNeverFollowsASymlinkOutsideItsNamespaceOrDropsItsOwnerRecordOnFailure() throws {
        try withBase { base in
            let outside = base.deletingLastPathComponent().appendingPathComponent("outside")
            let bytes = Data("canonical".utf8)
            try bytes.write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let prior = BpyHostStaging(base: base)
            let directory = try prior.directory("media-fixture"), namespace = directory.deletingLastPathComponent()
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: outside)
            try changeRecord(namespace) { $0["boot"] = try differentBoot().uuidString }
            do {
                try BpyHostStaging(base: base).prepare()
                Issue.record("A symlink escape did not stop recovery.")
            } catch {
                #expect(error.localizedDescription.contains(namespace.path))
                #expect(error.localizedDescription.contains("escape"))
                #expect(error.localizedDescription.contains("Symbolic links"))
                #expect(error.localizedDescription.contains("Quit NexGenVideo"))
            }
            #expect(try Data(contentsOf: outside) == bytes)
            #expect(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("owner.json").path))
            try FileManager.default.removeItem(at: directory.appendingPathComponent("escape"))
            try BpyHostStaging(base: base).prepare()
            #expect(!FileManager.default.fileExists(atPath: namespace.path))
        }
    }

    @Test func normalCloseRemovesOnlyEmptyDirectoriesAfterFilesHaveGone() throws {
        try withBase { base in
            let staging = BpyHostStaging(base: base)
            let directory = try staging.directory("session-fixture")
            let bytes = Data("reader-owned".utf8), url = directory.appendingPathComponent("frame.png")
            try bytes.write(to: url)
            #expect(throws: (any Error).self) { try staging.removeEmpty("session-fixture") }
            #expect(try Data(contentsOf: url) == bytes)
            try FileManager.default.removeItem(at: url)
            try staging.removeEmpty("session-fixture")
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    private func differentBoot() throws -> UUID {
        let current = try BpyStorageJournal.bootSessionID()
        var other = UUID()
        while other == current { other = UUID() }
        return other
    }

    private func changeRecord(_ directory: URL, _ change: (inout [String: Any]) throws -> Void) throws {
        let url = directory.appendingPathComponent("owner.json")
        var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try change(&value)
        try JSONSerialization.data(withJSONObject: value).write(to: url, options: .atomic)
    }

    private func withBase(_ body: (URL) throws -> Void) throws {
        let parent = URL(fileURLWithPath: try BpyRuntimePath.canonical(FileManager.default.temporaryDirectory))
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(parent.appendingPathComponent("staging"))
    }
}
