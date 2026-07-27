import Testing
@testable import NexGenVideo

@Suite("What's New policy")
struct ChangelogTests {
    @Test("an upgrade presents only when the current version has content")
    func upgradeRequiresCurrentEntry() {
        #expect(WhatsNewPolicy.shouldPresent(
            current: "1.0.0",
            lastSeen: "0.9.0",
            availableVersions: ["1.0.0"]
        ))
        #expect(!WhatsNewPolicy.shouldPresent(
            current: "1.0.0",
            lastSeen: "0.9.0",
            availableVersions: ["0.9.0"]
        ))
    }

    @Test("fresh installs and the already-seen version stay quiet")
    func freshAndSeenStayQuiet() {
        #expect(!WhatsNewPolicy.shouldPresent(
            current: "1.0.0",
            lastSeen: nil,
            availableVersions: ["1.0.0"]
        ))
        #expect(!WhatsNewPolicy.shouldPresent(
            current: "1.0.0",
            lastSeen: "1.0.0",
            availableVersions: ["1.0.0"]
        ))
    }
}
