import Foundation
import NexGenEngine

enum PipelineBiblePublication {
    enum Stage: Sendable, Equatable { case biblePersisted, variantsPersisted, beforeBibleRestore, beforeVariantsRestore }

    @TaskLocal static var failureProbe: (@Sendable (Stage) throws -> Void)?

    static func publish(bible: Bible, variants: BibleIdentityVariantsV1, dataRoot: URL) throws {
        let paths = [PipelineLayout.bibleFile, PipelineLayout.bibleIdentityVariantsFile]
        let previous = try paths.map { path -> Data? in
            let url = dataRoot.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return nil }
            return try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
        }
        do {
            try YAMLArtifactStore(dataRoot: dataRoot).save(bible, to: PipelineLayout.bibleFile)
            try failureProbe?(.biblePersisted)
            try BibleIdentityVariantStoreV1.save(variants, bible: bible, dataRoot: dataRoot)
            try failureProbe?(.variantsPersisted)
        } catch {
            let publicationFailure = error.localizedDescription
            var restorationFailures: [String] = []
            for (index, path) in paths.enumerated() {
                do {
                    try failureProbe?(index == 0 ? .beforeBibleRestore : .beforeVariantsRestore)
                    try restore(previous[index], path: path, dataRoot: dataRoot)
                } catch {
                    restorationFailures.append("\(path): \(error.localizedDescription)")
                }
            }
            throw HostOperationFailure(outcome: HostOperationOutcome(
                state: restorationFailures.isEmpty ? .rejectedBeforeWrite : .persistedButStructurallyInvalid,
                phase: "bible",
                diagnostic: "Bible publication failed: \(publicationFailure)."
                    + (restorationFailures.isEmpty ? " Prior artifact bytes were restored." : " Restoration failed: " + restorationFailures.joined(separator: "; "))
            ))
        }
    }

    private static func restore(_ bytes: Data?, path: String, dataRoot: URL) throws {
        let url = dataRoot.appendingPathComponent(path)
        let exists = FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
        if exists { _ = try ProjectLocalFile.resolve(path, dataRoot: dataRoot) }
        if let bytes {
            _ = try ProjectLocalFile.ensureDirectory(String(path[..<path.lastIndex(of: "/")!]), dataRoot: dataRoot)
            try bytes.write(to: url, options: .atomic)
        } else if exists {
            try FileManager.default.removeItem(at: url)
        }
    }
}
