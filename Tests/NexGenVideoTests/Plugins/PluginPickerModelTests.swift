import Foundation
import Testing

@testable import NexGenVideo

/// The picker's pure model layer: the headline/benefit card fallback and the
/// `Activate`-centered state machine (`PluginManager.buildRows`), both testable
/// without the network, disk, or a MainActor hop.
@Suite("Plugin picker model")
struct PluginPickerModelTests {

    // MARK: - Fixtures

    private static let app = "0.1.0"

    private func entry(
        id: String = "musicvideo", version: String = "0.0.1", minApp: String = "0.1.0",
        headline: String? = "Turn a song into a finished video.",
        benefit: String? = "Reads your track and plans shots to the beat.",
        badge: URL? = nil
    ) -> PluginCatalog.Entry {
        PluginCatalog.Entry(
            id: id, displayName: "Music Video Studio", tagline: "structured",
            headline: headline, benefit: benefit, version: version, minAppVersion: minApp,
            url: URL(string: "https://ex.com/\(id).ngvpack.zip")!, sha256: "abc", badge: badge)
    }

    private func record(
        id: String = "musicvideo", version: String = "0.0.1",
        headline: String = "Turn a song into a finished video.",
        benefit: String = "Reads your track and plans shots to the beat.",
        state: InstalledPluginRecord.State = .loaded
    ) -> InstalledPluginRecord {
        InstalledPluginRecord(
            id: id, displayName: "Music Video Studio", tagline: "structured",
            headline: headline, benefit: benefit, version: version, minAppVersion: "0.1.0",
            bundleURL: URL(fileURLWithPath: "/tmp/\(id).ngvpack"), state: state)
    }

    // MARK: - headline / benefit fallback

    @Test func cardPrefersHeadlineOverTagline() {
        let row = PluginRow(id: "x", displayName: "X", tagline: "jargon tagline",
                            headline: "Bold pitch.", benefit: "Short benefit.", badgeURL: nil,
                            status: .updatePendingRestart)
        #expect(row.pitch == "Bold pitch.")
        #expect(row.benefitLine == "Short benefit.")
    }

    @Test func cardFallsBackToTaglineWhenHeadlineMissing() {
        let row = PluginRow(id: "x", displayName: "X", tagline: "jargon tagline",
                            headline: nil, benefit: "orphan benefit", badgeURL: nil,
                            status: .updatePendingRestart)
        // No headline → the tagline is the pitch, and a benefit line is not shown on its own.
        #expect(row.pitch == "jargon tagline")
        #expect(row.benefitLine == nil)
    }

    @Test func emptyHeadlineCountsAsMissing() {
        let row = PluginRow(id: "x", displayName: "X", tagline: "tag", headline: "", benefit: "b",
                            badgeURL: nil, status: .updatePendingRestart)
        #expect(row.pitch == "tag")
        #expect(row.benefitLine == nil)
    }

    @Test func headlineWithoutBenefitShowsNoBenefitLine() {
        let row = PluginRow(id: "x", displayName: "X", tagline: "tag", headline: "Pitch.", benefit: nil,
                            badgeURL: nil, status: .updatePendingRestart)
        #expect(row.pitch == "Pitch.")
        #expect(row.benefitLine == nil)
    }

    // MARK: - state machine (buildRows / installedStatus / catalogStatus)

    private func status(of rows: [PluginRow], id: String) -> PluginRow.Status? {
        rows.first { $0.id == id }?.status
    }

    /// A compatible catalog pack that isn't installed → the single primary `Activate`.
    @Test func uninstalledCompatibleIsAvailable() {
        let rows = PluginManager.buildRows(
            installed: [], catalog: [entry()], activePluginName: nil, appVersion: Self.app)
        guard case .available = status(of: rows, id: "musicvideo") else {
            Issue.record("expected .available"); return
        }
    }

    /// A catalog pack that needs a newer app → unavailable with a calm reason, no button.
    @Test func uninstalledTooNewIsUnavailable() {
        let rows = PluginManager.buildRows(
            installed: [], catalog: [entry(minApp: "9.9.9")], activePluginName: nil, appVersion: Self.app)
        guard case .unavailable(let reason) = status(of: rows, id: "musicvideo") else {
            Issue.record("expected .unavailable"); return
        }
        #expect(reason == "Requires NexGenVideo 9.9.9 or newer.")
    }

    /// Installed but not this project's pack → installed, not active, no update offered.
    @Test func installedInactiveHasNoActiveNoUpdate() {
        let rows = PluginManager.buildRows(
            installed: [record()], catalog: [], activePluginName: nil, appVersion: Self.app)
        guard case .installed(let active, let update) = status(of: rows, id: "musicvideo") else {
            Issue.record("expected .installed"); return
        }
        #expect(active == false)
        #expect(update == nil)
    }

    /// The active pack of this project → installed + active (the picker shows Active + Remove).
    @Test func activePackIsMarkedActive() {
        let rows = PluginManager.buildRows(
            installed: [record()], catalog: [], activePluginName: "musicvideo", appVersion: Self.app)
        guard case .installed(let active, _) = status(of: rows, id: "musicvideo") else {
            Issue.record("expected .installed"); return
        }
        #expect(active == true)
    }

    /// A newer, installable catalog build over the installed one → an Update is offered.
    @Test func newerCatalogVersionOffersUpdate() {
        let rows = PluginManager.buildRows(
            installed: [record(version: "0.0.1")], catalog: [entry(version: "0.0.2")],
            activePluginName: "musicvideo", appVersion: Self.app)
        guard case .installed(_, let update) = status(of: rows, id: "musicvideo") else {
            Issue.record("expected .installed"); return
        }
        #expect(update?.version == "0.0.2")
    }

    /// A same-or-older catalog version never offers an update.
    @Test func sameCatalogVersionOffersNoUpdate() {
        let rows = PluginManager.buildRows(
            installed: [record(version: "0.0.2")], catalog: [entry(version: "0.0.2")],
            activePluginName: nil, appVersion: Self.app)
        guard case .installed(_, let update) = status(of: rows, id: "musicvideo") else {
            Issue.record("expected .installed"); return
        }
        #expect(update == nil)
    }

    /// A gate-blocked installed pack → incompatible with its calm reason.
    @Test func incompatibleInstalledShowsReason() {
        let rec = record(state: .incompatible(.requiresAppVersion("9.9.9")))
        let rows = PluginManager.buildRows(
            installed: [rec], catalog: [], activePluginName: nil, appVersion: Self.app)
        guard case .incompatible(let reason, _) = status(of: rows, id: "musicvideo") else {
            Issue.record("expected .incompatible"); return
        }
        #expect(reason == "Requires NexGenVideo 9.9.9 or newer.")
    }

    /// A newer build on disk with the old code still resident → restart-pending.
    @Test func updatePendingRestartMapsThrough() {
        let rows = PluginManager.buildRows(
            installed: [record(state: .updatePendingRestart)], catalog: [],
            activePluginName: nil, appVersion: Self.app)
        guard case .updatePendingRestart = status(of: rows, id: "musicvideo") else {
            Issue.record("expected .updatePendingRestart"); return
        }
    }

    /// buildRows carries headline/benefit onto the row so the card can show the real pitch.
    @Test func rowsCarryHeadlineAndBenefit() {
        let rows = PluginManager.buildRows(
            installed: [record()], catalog: [], activePluginName: nil, appVersion: Self.app)
        let row = try? #require(rows.first)
        #expect(row?.pitch == "Turn a song into a finished video.")
        #expect(row?.benefitLine == "Reads your track and plans shots to the beat.")
    }

    // MARK: - metadata decode of the new fields

    @Test func bundleInfoReadsHeadlineAndBenefit() {
        let info = PluginBundleInfo(plist: [
            PluginBundleInfo.Key.id: "musicvideo",
            PluginBundleInfo.Key.version: "0.0.1",
            PluginBundleInfo.Key.minAppVersion: "0.1.0",
            PluginBundleInfo.Key.principalClass: "MusicvideoPackEntry",
            PluginBundleInfo.Key.displayName: "Music Video Studio",
            PluginBundleInfo.Key.tagline: "structured",
            PluginBundleInfo.Key.headline: "Turn a song into a finished video.",
            PluginBundleInfo.Key.benefit: "Reads your track and plans shots to the beat.",
        ])
        #expect(info.headline == "Turn a song into a finished video.")
        #expect(info.benefit == "Reads your track and plans shots to the beat.")
    }

    @Test func bundleInfoHeadlineBenefitDefaultEmpty() {
        let info = PluginBundleInfo(plist: [PluginBundleInfo.Key.id: "x"])
        #expect(info.headline.isEmpty)
        #expect(info.benefit.isEmpty)
    }

    @Test func catalogDecodesHeadlineAndBenefit() throws {
        let catalog = try PluginCatalogService.decode("""
        {"plugins":[{"id":"musicvideo","displayName":"MV","tagline":"t","version":"0.0.1",
          "minAppVersion":"0.1.0","url":"https://ex.com/mv.ngvpack.zip","sha256":"abc",
          "headline":"Turn a song into a finished video.","benefit":"Reads your track."}]}
        """.data(using: .utf8)!)
        let e = try #require(catalog.plugins.first)
        #expect(e.headline == "Turn a song into a finished video.")
        #expect(e.benefit == "Reads your track.")
    }

    @Test func catalogHeadlineBenefitAreOptional() throws {
        let catalog = try PluginCatalogService.decode("""
        {"plugins":[{"id":"musicvideo","displayName":"MV","tagline":"t","version":"0.0.1",
          "minAppVersion":"0.1.0","url":"https://ex.com/mv.ngvpack.zip","sha256":"abc"}]}
        """.data(using: .utf8)!)
        let e = try #require(catalog.plugins.first)
        #expect(e.headline == nil)
        #expect(e.benefit == nil)
    }
}
