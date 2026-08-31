import CoreFoundation
import Foundation
import NexGenEngine

/// Metadata read from an installed `.ngvpack`'s `Contents/Info.plist` — the
/// values the load gate needs BEFORE any code is loaded.
struct PluginBundleInfo: Equatable {
    /// `NGVPackID` — the pack's activation id (also its filename stem).
    let id: String
    /// `NGVPackDisplayName` — gallery title.
    let displayName: String
    /// `NGVPackTagline` — gallery subtitle (may be empty).
    let tagline: String
    /// `NGVPackHeadline` — a bold one-line card pitch (may be empty → card uses tagline).
    let headline: String
    /// `NGVPackBenefit` — a short benefit line under the headline (may be empty).
    let benefit: String
    /// `CFBundleShortVersionString` — the pack's own version.
    let version: String
    /// `NGVProjectSchema` — the project-data contract written by this pack.
    let projectSchema: String
    /// `NGVMigratesFrom` — project schemas this pack can migrate transactionally.
    let migratesFrom: [String]
    /// `NGVMinAppVersion` — minimum NexGenVideo marketing version required.
    let minAppVersion: String
    /// `NGVEngineContract` — the host↔pack binary contract the pack was BUILT against, stamped by
    /// `assemble_ngvpack.sh`. `0` = absent or unparseable, i.e. a pack that predates the check.
    let engineContract: Int
    /// `NGVPipelineContractVersion` — 1 for packs that ship the declarative contract, 0 only for
    /// exact published pack builds in the host compatibility table.
    let pipelineContractVersion: Int
    /// `NGVPackResourceRoot` — the declared directory under Contents/Resources that owns every
    /// pipeline instruction, hard-step declaration, and extension schema.
    let resourceRoot: String
    /// `NSPrincipalClass` — the `PackEntry` subclass the host instantiates.
    let principalClass: String

    /// Plist keys, kept in one place so assembly (release.yml) and reading agree.
    enum Key {
        static let id = "NGVPackID"
        static let displayName = "NGVPackDisplayName"
        static let tagline = "NGVPackTagline"
        static let headline = "NGVPackHeadline"
        static let benefit = "NGVPackBenefit"
        static let version = "CFBundleShortVersionString"
        static let projectSchema = "NGVProjectSchema"
        static let migratesFrom = "NGVMigratesFrom"
        static let minAppVersion = "NGVMinAppVersion"
        static let engineContract = "NGVEngineContract"
        static let pipelineContractVersion = "NGVPipelineContractVersion"
        static let resourceRoot = "NGVPackResourceRoot"
        static let principalClass = "NSPrincipalClass"
    }

    /// Pure decode from a plist dictionary — the unit-testable core.
    init(plist: [String: Any]) {
        id = (plist[Key.id] as? String) ?? ""
        displayName = (plist[Key.displayName] as? String) ?? ""
        tagline = (plist[Key.tagline] as? String) ?? ""
        headline = (plist[Key.headline] as? String) ?? ""
        benefit = (plist[Key.benefit] as? String) ?? ""
        version = (plist[Key.version] as? String) ?? ""
        let declaredSchema = (plist[Key.projectSchema] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projectSchema = declaredSchema.flatMap { $0.isEmpty ? nil : $0 } ?? "\(id)/legacy"
        migratesFrom = (plist[Key.migratesFrom] as? [String]) ?? []
        minAppVersion = (plist[Key.minAppVersion] as? String) ?? ""
        // Only a genuine plist integer counts — a string ("2") or a missing key reads as 0 and is
        // refused, so an ambiguous stamp can never be mistaken for a matching contract.
        engineContract = Self.plistInteger(plist[Key.engineContract]) ?? 0
        pipelineContractVersion = Self.plistInteger(plist[Key.pipelineContractVersion]) ?? 0
        resourceRoot = ((plist[Key.resourceRoot] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        principalClass = (plist[Key.principalClass] as? String) ?? ""
    }

    private static func plistInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else {
            return nil
        }
        return number.intValue
    }

    /// Read from a `.ngvpack` bundle URL's `Contents/Info.plist`. Nil when the
    /// plist is missing or unparseable (surfaced as damaged metadata upstream).
    init?(bundleURL: URL) {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any]
        else { return nil }
        self.init(plist: dict)
    }
}

/// Why a pack can't be activated — each carries a calm, user-facing reason the
/// picker shows instead of crashing or silently skipping the pack.
enum PluginIncompatibility: Equatable {
    /// Missing or malformed id / version / principal class.
    case malformedMetadata(String)
    /// `NGVMinAppVersion` is newer than the running app.
    case requiresAppVersion(String)
    /// Code signature missing, invalid, or not from the host's Team ID.
    case untrustedSignature(String)
    /// The host supplied non-semantic marketing-version metadata.
    case invalidHostVersion(String)
    /// `NGVEngineContract` lies outside the running engine's explicit compatibility range.
    case requiresEngineContract(pack: Int, app: Int)

    var reason: String {
        switch self {
        case .malformedMetadata(let detail):
            return "Damaged pack — \(detail)."
        case .requiresAppVersion(let min):
            return "Requires NexGenVideo \(min) or newer."
        case .untrustedSignature(let detail):
            return "Signature check failed — \(detail)."
        case .invalidHostVersion:
            return "This NexGenVideo build has invalid version metadata."
        case .requiresEngineContract:
            return "Built for a different version of NexGenVideo — update the pack."
        }
    }
}

/// The metadata + version half of the load gate (pure; the signature half is IO
/// in `PluginSignature`). Returns the blocking reason, or nil when the pack
/// clears these checks.
enum PluginGate {
    static func evaluate(info: PluginBundleInfo, appVersion: String?) -> PluginIncompatibility? {
        guard PluginPaths.isValidID(info.id) else {
            return .malformedMetadata("missing or invalid pack id")
        }
        guard SemanticVersion(info.version) != nil else {
            return .malformedMetadata("invalid pack version \"\(info.version)\"")
        }
        guard isValidProjectSchema(info.projectSchema, packID: info.id) else {
            return .malformedMetadata("invalid project schema \"\(info.projectSchema)\"")
        }
        guard info.migratesFrom.allSatisfy({
            isValidProjectSchema($0, packID: info.id) && $0 != info.projectSchema
        }), Set(info.migratesFrom).count == info.migratesFrom.count else {
            return .malformedMetadata("invalid project migration declaration")
        }
        guard !info.principalClass.isEmpty else {
            return .malformedMetadata("no entry point declared")
        }
        // Version first: when the app is simply too old, "Requires NexGenVideo X" is the more
        // actionable reason than the contract mismatch that follows from it.
        if let reason = versionCheck(minAppVersion: info.minAppVersion, appVersion: appVersion) {
            return reason
        }
        return contractCheck(packContract: info.engineContract)
    }

    /// The binary-contract axis. Only the host's explicit inclusive compatibility range is accepted.
    static func contractCheck(
        packContract: Int,
        engine: Int = EngineContract.current,
        minimumCompatible: Int = EngineContract.minimumCompatible
    ) -> PluginIncompatibility? {
        guard (minimumCompatible...engine).contains(packContract) else {
            return .requiresEngineContract(pack: packContract, app: engine)
        }
        return nil
    }

    /// The version axis alone — reused by the picker to decide whether a catalog
    /// entry (which carries no principal class yet) is installable on this build.
    static func versionCheck(minAppVersion: String, appVersion: String?) -> PluginIncompatibility? {
        guard let minVersion = SemanticVersion(minAppVersion) else {
            return .malformedMetadata("invalid minimum app version \"\(minAppVersion)\"")
        }
        // Dev / CI builds without a marketing version are always compatible
        // (logged by the caller) — a bare `swift run` still loads local packs.
        guard let appVersionString = appVersion else {
            return nil
        }
        guard let app = SemanticVersion(appVersionString) else {
            return .invalidHostVersion(appVersionString)
        }
        guard app >= minVersion else {
            return .requiresAppVersion(minAppVersion)
        }
        return nil
    }

    private static func isValidProjectSchema(_ schema: String, packID: String) -> Bool {
        let components = schema.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == Substring(packID) else { return false }
        let revision = String(components[1])
        return revision == "legacy" || SemanticVersion(revision) != nil
    }
}
