import Foundation
import Testing

@testable import NexGenVideo

/// The two follow-up Codex security findings on the loadable-pack gate.
@Suite("Loadable-pack security — follow-up findings")
struct PluginSecurityFollowupTests {

    // Finding A: a rescan of an already-resident pack must not report a newer on-disk
    // version as live — a dylib can't be unloaded, so it's restart-required.

    @Test @MainActor func residentDecisionNotResidentProceedsToLoad() {
        #expect(PluginLoader.residentDecision(
            diskVersion: "1.0.0", residentVersion: nil, didRegister: false) == nil)
    }

    @Test @MainActor func residentDecisionSameVersionStaysLoaded() {
        #expect(PluginLoader.residentDecision(
            diskVersion: "1.0.0", residentVersion: "1.0.0", didRegister: true) == .loaded)
    }

    @Test @MainActor func residentDecisionNewerDiskVersionNeedsRestart() {
        #expect(
            PluginLoader.residentDecision(diskVersion: "2.0.0", residentVersion: "1.0.0", didRegister: true)
                == .updatePendingRestart
        )
        // Even a downgrade on disk is "different from what's live" → restart, never false-live.
        #expect(
            PluginLoader.residentDecision(diskVersion: "0.9.0", residentVersion: "1.0.0", didRegister: true)
                == .updatePendingRestart
        )
    }

    // The actual fix: a pack that loaded but failed its principal-class cast is resident but never
    // registered. A rescan of the SAME broken version must fall through (re-report the failure), but
    // once a NEWER version is staged on disk it must be restart-pending — not re-flagged "Damaged".

    @Test @MainActor func residentDecisionSameBrokenVersionFallsThroughToReReport() {
        #expect(PluginLoader.residentDecision(
            diskVersion: "1.0.0", residentVersion: "1.0.0", didRegister: false) == nil)
    }

    @Test @MainActor func residentDecisionUpdateToBrokenPackNeedsRestartNotDamaged() {
        #expect(
            PluginLoader.residentDecision(diskVersion: "2.0.0", residentVersion: "1.0.0", didRegister: false)
                == .updatePendingRestart
        )
    }

    // Finding B: a catalog-supplied badge is remote data — only https is honored, never a
    // file:// (which would turn a compromised catalog into a local file read).

    @Test func catalogBadgeHonorsHTTPSOnly() {
        #expect(PluginManager.catalogBadge(URL(string: "https://cdn.example.com/b.png")!)
                == URL(string: "https://cdn.example.com/b.png")!)
        #expect(PluginManager.catalogBadge(URL(string: "HTTPS://cdn.example.com/b.png")!) != nil)
    }

    @Test func catalogBadgeRejectsFileAndNonHTTPS() {
        #expect(PluginManager.catalogBadge(URL(fileURLWithPath: "/etc/passwd")) == nil)
        #expect(PluginManager.catalogBadge(URL(string: "file:///etc/passwd")!) == nil)
        #expect(PluginManager.catalogBadge(URL(string: "http://cdn.example.com/b.png")!) == nil)
        #expect(PluginManager.catalogBadge(URL(string: "ftp://cdn.example.com/b.png")!) == nil)
        #expect(PluginManager.catalogBadge(nil) == nil)
    }
}
