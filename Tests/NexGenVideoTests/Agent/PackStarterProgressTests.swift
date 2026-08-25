import Foundation
import Testing
import NexGenEngine
import MusicvideoPlugin

@testable import NexGenVideo

/// The starter chip must speak to the project the user actually has open.
@Suite("pack starters follow project progress")
struct PackStarterProgressTests {

    private let pack = MusicvideoPack()

    @Test("an untouched project is offered the start chip")
    func untouchedOffersStart() {
        let starters = pack.starters(for: .untouched)
        #expect(starters.first?.id == "start")
        #expect(starters.first?.title == "Start the music video")
        #expect(starters.first?.prompt.contains("host initialized") == true)
        #expect(starters.first?.prompt.contains("Track plus optional Lyrics") == true)
        #expect(starters.first?.prompt.contains("# Phase K0 — Project Init") == true)
        #expect(starters.first?.prompt.contains(
            "Do not ask for or develop a story before Audio Analysis is approved."
        ) == true)
        #expect(starters.first?.prompt.lowercased().contains("asking me for the track") == false)
    }

    @Test("a project with approved phases is offered CONTINUE, naming the next phase")
    func startedOffersContinue() throws {
        // The field case: Project Init + Audio Analysis approved, Brief next.
        let progress = PackProgress(nextPhase: "brief", approvedPhases: 2, totalPhases: 11)
        let starter = try #require(pack.starters(for: progress).first)

        #expect(starter.id == "continue")
        #expect(starter.title.contains("Brief"))
        let prompt = starter.prompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        // The prompt must not restart the pipeline or re-request the song.
        #expect(!prompt.lowercased().contains("ask me for the track"))
        #expect(prompt.contains("Brief"))
        #expect(prompt.contains("# Phase K1 — Brief"))
        #expect(prompt.contains("If it is absent, this is greenfield"))
    }

    @Test("the phase in the chip is the pack's own wording, not the raw key")
    func labelsAreHumanReadable() {
        let progress = PackProgress(nextPhase: "production_design", approvedPhases: 3, totalPhases: 11)
        #expect(pack.starters(for: progress).first?.title.contains("Production Design") == true)
        // An unknown phase still reads as words rather than a snake_case key.
        let unknown = PackProgress(nextPhase: "colour_grade", approvedPhases: 1, totalPhases: 11)
        #expect(pack.starters(for: unknown).first?.title.contains("Colour Grade") == true)
    }

    @Test("a fully approved project offers the optional post-pipeline cover utility")
    func completeProjectOffersCoverUtility() throws {
        let progress = PackProgress(nextPhase: nil, approvedPhases: 11, totalPhases: 11)
        let starter = try #require(pack.starters(for: progress).first)
        #expect(starter.id == "cover")
        #expect(starter.id != "start")
        #expect(starter.prompt.contains("# Post-pipeline utility — Cover Images"))
        #expect(starter.prompt.contains("It has no gate"))
        #expect(starter.prompt.contains("instructions for the optional utility"))
        #expect(!starter.prompt.contains("instructions for the current phase"))
    }

    @Test("progress reports whether anything is approved")
    func progressFlags() {
        #expect(PackProgress.untouched.hasStarted == false)
        #expect(PackProgress(nextPhase: "brief", approvedPhases: 2, totalPhases: 11).hasStarted)
        #expect(PackProgress(nextPhase: nil, approvedPhases: 11, totalPhases: 11).isComplete)
        #expect(PackProgress(nextPhase: "brief", approvedPhases: 2, totalPhases: 11).isComplete == false)
    }

    @Test("the catalog hands the pack the project's progress")
    func catalogPassesProgress() throws {
        // Guards the wiring: if `discover` stopped forwarding progress, every project would silently
        // fall back to the start chip again — the exact regression this fixes.
        // The catalog is empty until a pack registers (packs ship as loadable bundles), and
        // registration is idempotent by name — safe alongside the other suites that do the same.
        PackCatalog.register(MusicvideoPack())
        let progress = PackProgress(nextPhase: "brief", approvedPhases: 2, totalPhases: 11)
        let musicvideo = try #require(
            PluginCommandCatalog.discover(progress: progress).first { $0.name == "musicvideo" })
        #expect(musicvideo.commands.first?.title.contains("Brief") == true)

        let gallery = try #require(
            PluginCommandCatalog.discover().first { $0.name == "musicvideo" })
        #expect(gallery.commands.first?.title == "Start the music video")
    }
}
