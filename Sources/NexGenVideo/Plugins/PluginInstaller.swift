import CryptoKit
import Foundation
import NexGenEngine

/// Downloads, verifies, and installs a catalog pack, then loads it through the
/// same gate as a startup pack.
///
/// The install is staged and atomic: the download is checksum-verified, unpacked
/// into a temp dir, and run through ALL non-executing gates (metadata, minAppVersion,
/// code signature) THERE — the working install on disk is only swapped once every
/// gate has passed. A bad bundle therefore can never overwrite a good one. Pack
/// URLs must be https (defense against a tampered catalog pointing at plaintext).
@MainActor
enum PluginInstaller {
    private static var inFlight: [String: Task<InstalledPluginRecord, Error>] = [:]

    enum InstallError: LocalizedError {
        case insecureURL(String)
        case download(String)
        case checksumMismatch(expected: String, actual: String)
        case unpack(String)
        case idMismatch(expected: String, found: String)
        case versionMismatch(expected: String, found: String)
        case schemaMismatch(expected: String, found: String)
        case gate(PluginIncompatibility)

        var errorDescription: String? {
            switch self {
            case .insecureURL(let url):
                return "Refused an insecure pack URL — \(url). Packs must be served over HTTPS."
            case .download(let detail): return "Download failed — \(detail)."
            case .checksumMismatch:
                return "The download didn't match its checksum and was discarded."
            case .unpack(let detail): return "Couldn't unpack the pack — \(detail)."
            case .idMismatch(let expected, let found):
                return "The pack identifies as \"\(found)\" but the catalog listed \"\(expected)\"."
            case .versionMismatch(let expected, let found):
                return "The pack is version \(found), but the catalog listed \(expected)."
            case .schemaMismatch(let expected, let found):
                return "The pack's project schema is \(found), but the catalog listed \(expected)."
            case .gate(let reason): return reason.reason
            }
        }
    }

    /// Install (or update) `entry` over the network. Thin wrapper over the staged
    /// pipeline with the real downloader injected.
    @discardableResult
    static func install(
        _ entry: PluginCatalog.Entry,
        appVersion: String? = AppVersion.marketing
    ) async throws -> InstalledPluginRecord {
        if let existing = inFlight[entry.id] {
            let record = try await existing.value
            if record.version == entry.version {
                return record
            }
            return try await install(entry, appVersion: appVersion)
        }
        let task = Task { @MainActor in
            defer { inFlight.removeValue(forKey: entry.id) }
            return try await install(
                entry,
                appVersion: appVersion,
                fetch: { try await download($0) }
            )
        }
        inFlight[entry.id] = task
        return try await task.value
    }

    /// The staged install pipeline: https-guard → fetch → checksum → unpack → gate the
    /// STAGED copy → atomically swap into place → load (only when this id isn't already
    /// resident). `fetch` is injected so the checksum/gate/swap ordering is testable
    /// offline. Throws `InstallError` with a user-facing reason; on any failure the
    /// prior install is left intact.
    @discardableResult
    static func install(
        _ entry: PluginCatalog.Entry,
        appVersion: String?,
        fetch: @MainActor (URL) async throws -> Data
    ) async throws -> InstalledPluginRecord {
        guard PluginPaths.isValidID(entry.id) else {
            throw InstallError.unpack("the catalog id \"\(entry.id)\" is invalid")
        }
        // Finding 5: reject non-https pack URLs before any network access.
        guard isHTTPS(entry.url) else {
            throw InstallError.insecureURL(entry.url.absoluteString)
        }

        let data = try await fetch(entry.url)

        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
            throw InstallError.checksumMismatch(expected: entry.sha256, actual: actual)
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngvpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zipURL = work.appendingPathComponent("pack.zip")
        try data.write(to: zipURL)
        let extractDir = work.appendingPathComponent("x", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try unzip(zipURL, into: extractDir)

        guard let unpacked = firstBundle(in: extractDir) else {
            throw InstallError.unpack("no .ngvpack inside the archive")
        }
        guard let info = PluginBundleInfo(bundleURL: unpacked) else {
            throw InstallError.gate(.malformedMetadata("its Info.plist is missing or unreadable"))
        }
        guard info.id == entry.id else {
            throw InstallError.idMismatch(expected: entry.id, found: info.id)
        }
        guard info.version == entry.version else {
            throw InstallError.versionMismatch(expected: entry.version, found: info.version)
        }
        guard info.projectSchema == entry.projectSchema else {
            throw InstallError.schemaMismatch(
                expected: entry.projectSchema,
                found: info.projectSchema
            )
        }
        guard Set(info.migratesFrom) == Set(entry.migratesFrom) else {
            throw InstallError.schemaMismatch(
                expected: entry.migratesFrom.joined(separator: ", "),
                found: info.migratesFrom.joined(separator: ", ")
            )
        }

        // Finding 3: run every non-executing gate on the STAGED copy in temp, before
        // touching the installed pack. A failure here throws and leaves disk untouched.
        if let reason = PluginGate.evaluate(info: info, appVersion: appVersion) {
            throw InstallError.gate(reason)
        }
        if let reason = PluginSignature.verify(bundleURL: unpacked, host: PluginSignature.hostSigningState()) {
            throw InstallError.gate(reason)
        }

        // Capture "already resident this process" BEFORE the swap. A dylib for this id can't be
        // unloaded, so the new code can't go live until relaunch. Use RESIDENCY (was the code ever
        // mapped in?), not registration — a pack that loaded but failed to register (a broken build)
        // is still resident, so its update also needs a restart rather than re-showing "Damaged".
        let alreadyLoaded = PluginLoader.isResident(entry.id)

        // All gates passed — now atomically swap the validated bundle into place.
        try moveIntoPlace(unpacked, id: entry.id, version: entry.version)
        let dest = PluginPaths.installURL(id: entry.id, version: entry.version)
        PluginLoader.clearRuntimeRejection(
            id: entry.id,
            version: entry.version
        )

        if alreadyLoaded {
            return PluginLoader.markUpdatePendingRestart(info, bundleURL: dest)
        }

        guard let binding = ProjectPackBinding(
            id: entry.id,
            version: info.version,
            projectSchema: info.projectSchema
        ), let record = PluginLoader.activate(binding, appVersion: appVersion) else {
            throw InstallError.unpack("the installed pack didn't reappear in the library")
        }
        if let reason = record.incompatibility { throw InstallError.gate(reason) }
        return record
    }

    /// Whether `url`'s scheme is https (case-insensitive) — the only scheme a pack
    /// (or badge) may be fetched over. Pure (no actor state) → `nonisolated` so the
    /// synchronous unit tests can call it without a MainActor hop.
    nonisolated static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    /// Remove an installed pack from disk. The already-loaded code stays live
    /// until the next launch (dylibs can't be safely unloaded mid-session), but
    /// it won't reload — the picker reflects that immediately.
    static func uninstall(id: String) throws {
        for url in [PluginPaths.installURL(id: id), PluginPaths.versionDirectory(id: id)] {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Steps

    private static func download(_ url: URL) async throws -> Data {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw InstallError.download("HTTP \(http.statusCode)")
            }
            guard !data.isEmpty else { throw InstallError.download("empty response") }
            return data
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.download(error.localizedDescription)
        }
    }

    private static func unzip(_ zip: URL, into dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, dir.path]
        do { try process.run() } catch { throw InstallError.unpack(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.unpack("archive extraction failed")
        }
    }

    private static func firstBundle(in dir: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.pathExtension == PluginPaths.bundleExtension }
    }

    /// Atomically place an immutable version beside every other installed version.
    private static func moveIntoPlace(
        _ unpacked: URL,
        id: String,
        version: String
    ) throws {
        let directory = PluginPaths.versionDirectory(id: id)
        let dest = PluginPaths.installURL(id: id, version: version)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let staging = directory
            .appendingPathComponent(".staging-\(UUID().uuidString).\(PluginPaths.bundleExtension)")
        do {
            try FileManager.default.copyItem(at: unpacked, to: staging)
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw InstallError.unpack(error.localizedDescription)
        }
    }
}
