import Foundation
import Security

/// The signature half of the load gate. A pack's `.ngvpack` must carry a valid
/// code signature, and — when the host app is itself Developer ID signed — must
/// share the host's Team ID (the same-developer requirement, derived from the
/// host's own signing rather than a hard-coded team). When the host is
/// ad-hoc/unsigned (dev, CI), a validly ad-hoc pack is accepted and logged.
enum PluginSignature {
    /// The Team ID the running app is signed with, or nil when the host is
    /// unsigned / ad-hoc. Read once from the host's own static code.
    static func hostTeamIdentifier() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else { return nil }
        return teamIdentifier(of: staticCode)
    }

    /// Verify the pack at `bundleURL`. Returns nil on success, or the blocking
    /// reason. `hostTeam` nil means the host is ad-hoc/unsigned.
    static func verify(bundleURL: URL, hostTeam: String?) -> PluginIncompatibility? {
        var staticRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else {
            return .untrustedSignature("no code signature")
        }
        // Integrity: the code seal must validate (ad-hoc counts as valid; a
        // tampered or unsigned bundle does not).
        guard SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else {
            return .untrustedSignature("the pack isn't validly signed")
        }
        let packTeam = teamIdentifier(of: staticCode)
        if let hostTeam {
            guard packTeam == hostTeam else {
                return .untrustedSignature("not signed by this app's developer")
            }
            return nil
        }
        // Ad-hoc / unsigned host (dev, CI): accept the validated pack and log it.
        Log.plugins.notice("host is unsigned/ad-hoc — accepting \(bundleURL.lastPathComponent) without a Team ID match")
        return nil
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
