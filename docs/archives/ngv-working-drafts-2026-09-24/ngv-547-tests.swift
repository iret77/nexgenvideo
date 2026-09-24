import Foundation
import Testing
@testable import NexGenEngine

@Suite("Complete 3.4 source retrieval")
struct ProductionKnowledgeArchive34Tests {
    @Test func completeInventoryAndExactReceipts() throws {
        let archive = try EngineProductionKnowledgeResourcesV1.loadArchive34()
        for (kind, count) in [("section", 297), ("unit", 682), ("blueprint", 42),
                              ("runbook", 10), ("table", 59), ("template", 21)] {
            let records = archive.records.filter { $0.kind == kind }
            #expect(records.count == count)
            for record in records {
                let read = try archive.read(record.id)
                #expect(read.receipt.sha256 == FileDigest.sha256(of: Data(read.record.text.utf8)))
                #expect(read.receipt.utf8Bytes == read.record.text.utf8.count)
            }
        }
        let w10 = try archive.read("W10")
        #expect(w10.record.text.lowercased().contains("animatic"))
        #expect(w10.record.text.contains("sheets"))
        #expect(w10.record.text.contains("production"))
        #expect(w10.record.text == archive.records.first { $0.id == w10.record.sectionID }?.text)
    }

    @Test func blockPlanReadsSharedChecksWithoutCaptionSpineForm() throws {
        let archive = try EngineProductionKnowledgeResourcesV1.loadArchive34()
        let reads = try archive.readTechnique("B")
        let ids = Set(reads.map { $0.receipt.recordID })
        #expect(ids.contains("video-prompting-2754d80e7b56-u11921"))
        #expect(ids.contains("video-prompting-2754d80e7b56-u4880"))
        #expect(!ids.contains("video-prompting-2754d80e7b56"))
        #expect(!reads.map(\.record.text).joined().contains("Form — eight elements"))
        #expect(try archive.readTechnique("A").map(\.receipt.recordID) == ["video-prompting-2754d80e7b56"])
    }

    @Test func masterStylePlanCarriesOneMediumAndCompleteForm() throws {
        let archive = try EngineProductionKnowledgeResourcesV1.loadArchive34()
        let media = archive.records.filter { $0.kind == "medium-row" }
        let selected = try #require(media.first { $0.title.lowercased().contains("sumi") })
        let reads = try archive.readTechnique("C", mediumID: selected.id)
        #expect(reads.filter { $0.record.kind == "medium-row" }.map(\.record.id) == [selected.id])
        let text = reads.map(\.record.text).joined(separator: "\n")
        #expect(text.contains("MUST NOT APPEAR"))
        #expect(text.contains("Filled example"))
        #expect(!reads.map(\.record.id).contains("style-control-229b9a58a150"))
        #expect(!reads.map(\.record.id).contains("video-prompting-2754d80e7b56"))
        for other in media where other.id != selected.id {
            #expect(!text.contains(other.text))
        }
        #expect(throws: (any Error).self) { try archive.readTechnique("C") }
        #expect(throws: (any Error).self) { try archive.readTechnique("A", mediumID: selected.id) }
        #expect(throws: (any Error).self) { try archive.readTechnique("D") }
    }

    @Test func unitsUseUnicodeScalarsAndRetainFullSourceExceptions() throws {
        let archive = try EngineProductionKnowledgeResourcesV1.loadArchive34()
        let sections = Dictionary(uniqueKeysWithValues: archive.records.filter { $0.kind == "section" }.map { ($0.id, $0) })
        for record in archive.records where record.kind == "unit" {
            let section = try #require(sections[record.sectionID])
            let start = try #require(record.startCharacter)
            let end = try #require(record.endCharacter)
            let scalars = Array(section.text.unicodeScalars)
            #expect(record.text == String(String.UnicodeScalarView(scalars[start..<end])))
        }
        let lint = try archive.read("video-prompting-2754d80e7b56-u11921")
        #expect(lint.record.text.contains("seven measures"))
        #expect(lint.record.text.contains("ENDING STATE"))
    }

    @Test func baselineResourcesRemainTheSameSnapshot() throws {
        let baseline = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let video = try #require(baseline.library(id: .init(rawValue: "film-production-video-prompting")))
        #expect(video.version.rawValue == "3.1.1")
        #expect(video.provenance.sourceCommit == "0333751214c7af17977dd33f0ba88ba9c352421e")
    }
}
