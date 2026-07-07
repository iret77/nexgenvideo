import Foundation
import Testing

@testable import NexGenVideo

/// The pure signature-policy decision table (`PluginSignature.evaluate`). The real
/// `SecStaticCodeCheckValidity` calls need a signed fixture, so the accept/reject
/// logic is factored out and exercised here with stubbed evaluators — covering the
/// host-state enum branches and the "ad-hoc packs only when the host is ad-hoc" rule.
@Suite("Loadable-pack signature policy")
struct PluginSignatureTests {
    private func decide(
        host: PluginSignature.HostSigningState,
        sameDeveloper: Bool? = false,
        sealValid: Bool = true
    ) -> PluginIncompatibility? {
        PluginSignature.evaluate(
            host: host,
            bundleName: "pack.ngvpack",
            satisfiesSameDeveloper: { _ in sameDeveloper },
            sealValid: { sealValid })
    }

    // MARK: - Fail closed

    @Test func indeterminateHostFailsClosed() {
        // A Security.framework error reading the host's own signature must REJECT —
        // never fall through to the ad-hoc path, even for an otherwise-valid pack.
        let reason = decide(host: .error(-67000), sameDeveloper: true, sealValid: true)
        #expect(reason != nil)
        if case .untrustedSignature = reason {} else {
            Issue.record(".error host must yield an untrustedSignature block")
        }
    }

    // MARK: - Developer ID host requires the same-developer trust chain

    @Test func developerIDHostAcceptsSameDeveloperPack() {
        #expect(decide(host: .developerID(teamID: "ABCDE12345"), sameDeveloper: true) == nil)
    }

    @Test func developerIDHostRejectsForeignPack() {
        // Requirement failed (wrong team / not anchored to Apple) → rejected, even
        // though the bundle's own seal is internally valid.
        let reason = decide(host: .developerID(teamID: "ABCDE12345"), sameDeveloper: false, sealValid: true)
        #expect(reason == .untrustedSignature("not signed by this app's developer"))
    }

    @Test func developerIDHostRejectsWhenRequirementCannotBuild() {
        let reason = decide(host: .developerID(teamID: "ABCDE12345"), sameDeveloper: nil)
        #expect(reason != nil)
        if case .untrustedSignature = reason {} else {
            Issue.record("an unbuildable requirement must reject")
        }
    }

    // MARK: - Ad-hoc packs are accepted ONLY when the host is ad-hoc

    @Test func adhocHostAcceptsValidlySealedPack() {
        #expect(decide(host: .adhocOrUnsigned, sameDeveloper: false, sealValid: true) == nil)
    }

    @Test func adhocHostRejectsBrokenSeal() {
        let reason = decide(host: .adhocOrUnsigned, sealValid: false)
        #expect(reason == .untrustedSignature("the pack isn't validly signed"))
    }

    /// The core rule: a pack that does NOT satisfy the same-developer requirement
    /// (an ad-hoc / foreign pack) is accepted under an ad-hoc host but rejected under
    /// a Developer ID host. Ad-hoc acceptance is gated on the host being ad-hoc.
    @Test func adhocPackAcceptedOnlyWhenHostAdhoc() {
        // Same pack (fails the same-developer requirement, seal internally valid):
        #expect(decide(host: .adhocOrUnsigned, sameDeveloper: false, sealValid: true) == nil)
        #expect(decide(host: .developerID(teamID: "ABCDE12345"), sameDeveloper: false, sealValid: true) != nil)
    }

    // MARK: - Host state detection returns a concrete state (no crash)

    @Test func hostSigningStateResolves() {
        // On the test host this is `.adhocOrUnsigned` (ad-hoc `swift test` binary) or
        // `.developerID`; it must never be `.error` under normal conditions.
        let state = PluginSignature.hostSigningState()
        if case .error(let status) = state {
            Issue.record("host signing state unexpectedly errored: OSStatus \(status)")
        }
    }
}
