import Foundation
import Security

/// The signature half of the load gate.
///
/// A pack's `.ngvpack` must be validated against a real trust chain, not just its
/// own designated requirement (a self-signed bundle satisfies its OWN DR, so a bare
/// `SecStaticCodeCheckValidity(code, [], nil)` + a string compare of the Team ID is
/// NOT a trust check). When the host app is Developer ID signed we validate the pack
/// against the *same-developer* requirement Apple documents —
/// `anchor apple generic and certificate leaf[subject.OU] = "<hostTeamID>"` — which
/// requires the pack to chain to an Apple root AND carry the host's leaf Team ID.
///
/// The host's own signing state is modelled explicitly so it can never *fail open*:
/// a transient Security.framework error is `.error` and rejects the pack (fail
/// closed); ad-hoc packs are accepted ONLY when the host is positively ad-hoc /
/// unsigned (dev, CI). Each branch is logged.
enum PluginSignature {
    /// How the running app is itself signed — the axis that decides which trust
    /// policy a pack is held to. Positively distinguishes "the host is genuinely
    /// ad-hoc/unsigned" (ad-hoc packs allowed) from "we couldn't tell" (fail closed).
    enum HostSigningState: Equatable {
        /// Developer ID signed: packs must meet the same-developer requirement.
        case developerID(teamID: String)
        /// Genuinely ad-hoc or unsigned (dev / CI): a validly-sealed pack is allowed.
        case adhocOrUnsigned
        /// The host's signing couldn't be determined — every pack is rejected.
        case error(OSStatus)
    }

    /// Read the running app's signing state once, from its own static code. Any
    /// Security.framework failure is surfaced as `.error(status)` — never collapsed
    /// into the ad-hoc path, so a transient failure in a SIGNED build cannot open
    /// the ad-hoc door.
    static func hostSigningState() -> HostSigningState {
        var codeRef: SecCode?
        let selfStatus = SecCodeCopySelf([], &codeRef)
        guard selfStatus == errSecSuccess, let code = codeRef else { return .error(selfStatus) }

        var staticRef: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticRef)
        guard staticStatus == errSecSuccess, let staticCode = staticRef else { return .error(staticStatus) }

        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        guard infoStatus == errSecSuccess, let info = infoRef as? [String: Any] else {
            return .error(infoStatus)
        }
        // A Developer ID app always carries a Team ID; an ad-hoc / unsigned one
        // never does. That presence is the discriminator.
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return .developerID(teamID: team)
        }
        return .adhocOrUnsigned
    }

    /// Verify the pack at `bundleURL` against the host's signing state. Returns nil
    /// on success, or the blocking reason.
    static func verify(bundleURL: URL, host: HostSigningState) -> PluginIncompatibility? {
        var staticRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else {
            return .untrustedSignature("no code signature")
        }
        return evaluate(
            host: host,
            bundleName: bundleURL.lastPathComponent,
            satisfiesSameDeveloper: { teamID in
                guard let requirement = Self.sameDeveloperRequirement(teamID: teamID) else { return nil }
                return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
            },
            sealValid: {
                SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
            })
    }

    /// The pure policy — the decision table, factored out of the SecCode IO so the
    /// accept/reject logic is unit-testable. `satisfiesSameDeveloper(teamID)` returns
    /// nil only when the requirement object itself couldn't be built (→ reject).
    static func evaluate(
        host: HostSigningState,
        bundleName: String,
        satisfiesSameDeveloper: (String) -> Bool?,
        sealValid: () -> Bool
    ) -> PluginIncompatibility? {
        switch host {
        case .error(let status):
            Log.plugins.warning("host signing state indeterminate (OSStatus \(status)) — rejecting \(bundleName)")
            return .untrustedSignature("the app's own signature couldn't be verified")

        case .developerID(let teamID):
            guard let passes = satisfiesSameDeveloper(teamID) else {
                Log.plugins.warning("couldn't build the same-developer requirement for team \(teamID) — rejecting \(bundleName)")
                return .untrustedSignature("couldn't verify the developer requirement")
            }
            guard passes else {
                Log.plugins.warning("\(bundleName) failed the same-developer requirement (host team \(teamID))")
                return .untrustedSignature("not signed by this app's developer")
            }
            Log.plugins.notice("\(bundleName) satisfied the same-developer requirement (host team \(teamID))")
            return nil

        case .adhocOrUnsigned:
            guard sealValid() else {
                Log.plugins.warning("\(bundleName) isn't validly signed — rejecting (host is ad-hoc/unsigned)")
                return .untrustedSignature("the pack isn't validly signed")
            }
            Log.plugins.notice("host is unsigned/ad-hoc — accepting \(bundleName) without a Team ID match")
            return nil
        }
    }

    /// The same-developer requirement: the pack must chain to an Apple root AND its
    /// signing leaf's OU (the Team ID) must equal the host's. A self-signed bundle
    /// fails `anchor apple generic`, so it can never masquerade as ours.
    private static func sameDeveloperRequirement(teamID: String) -> SecRequirement? {
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }
}
