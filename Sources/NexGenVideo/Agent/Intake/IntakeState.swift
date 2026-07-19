import Foundation
import NexGenEngine

/// Whether a hard step's material is already in the project. Derived from the FILESYSTEM, never from
/// a flag: a project mid-pipeline (song attached, analysis approved) must never be asked for its song
/// again, and the material on disk is the only durable record that survives a fresh agent session.
enum IntakeSatisfaction {

    /// Loose style references live directly in `import/` (subdirs are identity anchors).
    static let styleReferenceExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "avif", "heic", "heif", "gif", "tiff"]

    static func isSatisfied(_ kind: HardStep.Kind, dataRoot: URL) -> Bool {
        fingerprint(kind, dataRoot: dataRoot) > 0
    }

    /// How much of the kind's material is on disk. A COUNT, not a flag: a repeatable identity step has
    /// to tell "the user attached another one" from "the user is done", and only the count moves.
    static func fingerprint(_ kind: HardStep.Kind, dataRoot: URL) -> Int {
        switch kind {
        case .song:
            return AudioProjectLayout.songFiles(dataRoot: dataRoot).count
        case .lyrics:
            return isNonEmptyFile(dataRoot.appendingPathComponent("lyrics/lyrics.txt")) ? 1 : 0
        case .script:
            return isNonEmptyFile(dataRoot.appendingPathComponent("import/script.md")) ? 1 : 0
        case .character:
            return populatedIdentityCount(dataRoot.appendingPathComponent("import/characters", isDirectory: true))
        case .location:
            return populatedIdentityCount(dataRoot.appendingPathComponent("import/locations", isDirectory: true))
        case .style:
            return styleReferenceCount(dataRoot.appendingPathComponent("import", isDirectory: true))
        }
    }

    private static func isNonEmptyFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return (values?.isRegularFile ?? false) && (values?.fileSize ?? 0) > 0
    }

    /// Subdirectories holding at least one real file. The scaffold pre-creates `import/characters/`
    /// with a `.gitkeep`, so the directory existing proves nothing.
    private static func populatedIdentityCount(_ dir: URL) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false else { return false }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            return files.contains { $0.lastPathComponent != ".gitkeep" }
        }.count
    }

    private static func styleReferenceCount(_ dir: URL) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { entry in
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false else { return false }
            return styleReferenceExtensions.contains(entry.pathExtension.lowercased())
        }.count
    }
}

/// The host's record of which optional hard steps the user has already turned down. Without it an
/// optional step is offered on every entry into its phase, forever — satisfaction alone can't tell
/// "not provided yet" from "declined".
///
/// Host-owned and separate from `project.yaml`, which the engine owns.
struct IntakeLedger: Equatable, Sendable {

    static let filename = "intake.json"
    private static let schema = "intake/1.0"

    private(set) var declined: Set<String>

    init(declined: Set<String> = []) { self.declined = declined }

    func isDeclined(_ stepId: String) -> Bool { declined.contains(stepId) }

    static func url(dataRoot: URL) -> URL { dataRoot.appendingPathComponent(filename) }

    /// A missing, unreadable, or malformed ledger reads as "nothing declined" — the user is asked
    /// once more, which is the safe direction: the mandatory step is never silently skipped.
    static func load(dataRoot: URL) -> IntakeLedger {
        guard let data = try? Data(contentsOf: url(dataRoot: dataRoot)),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return IntakeLedger() }
        return IntakeLedger(declined: Set(file.declined ?? []))
    }

    /// Records a turned-down step. A REQUIRED step is never recordable — taking the step itself rather
    /// than its id makes "required steps can't be declined" structural instead of a caller's duty.
    @discardableResult
    static func recordDecline(_ step: HardStep, dataRoot: URL) -> IntakeLedger {
        var ledger = load(dataRoot: dataRoot)
        guard !step.required else { return ledger }
        ledger.declined.insert(step.id)
        ledger.save(dataRoot: dataRoot)
        return ledger
    }

    func save(dataRoot: URL) {
        let file = File(schema: Self.schema, declined: declined.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: Self.url(dataRoot: dataRoot), options: .atomic)
    }

    private struct File: Codable {
        let schema: String
        var declined: [String]?
    }
}
