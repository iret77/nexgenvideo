import Foundation
import NexGenEngine

enum PipelineBibleWriter {
    static func write(_ bible: Bible, variants: BibleIdentityVariantsV1, dataRoot: URL) throws {
        try bible.validate()
        for path in referencePaths(bible) {
            _ = try FrameRasterizer.loadImage(at: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
        }
        try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: dataRoot, validateVariants: false)
        try BibleIdentityVariantStoreV1.validate(variants, bible: bible, dataRoot: dataRoot)
        let current = [PipelineLayout.bibleFile, PipelineLayout.bibleIdentityVariantsFile]
        let archives = try current.compactMap { path -> (path: String, bytes: Data)? in
            guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) else { return nil }
            let original = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
            let parent = (path as NSString).deletingLastPathComponent
            let archive = parent + "/history/" + original.deletingPathExtension().lastPathComponent
                + "-" + UUID().uuidString.lowercased() + "." + original.pathExtension
            return (archive, try Data(contentsOf: original))
        }
        try ArtifactTransaction.perform(paths: (current + archives.map(\.path)).map { dataRoot.appendingPathComponent($0) }, dataRoot: dataRoot) {
            for archive in archives {
                _ = try ProjectLocalFile.ensureDirectory((archive.path as NSString).deletingLastPathComponent, dataRoot: dataRoot)
                try archive.bytes.write(to: dataRoot.appendingPathComponent(archive.path), options: .atomic)
            }
            try YAMLArtifactStore(dataRoot: dataRoot).save(bible, to: PipelineLayout.bibleFile)
            try BibleIdentityVariantStoreV1.save(variants, bible: bible, dataRoot: dataRoot)
            try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: dataRoot)
        }
    }

    static func referencePaths(_ bible: Bible) -> [String] {
        var paths = bible.characters.flatMap { $0.referenceImages + Array($0.sheets.values) }
            + bible.ensembles.flatMap { $0.referenceImages + Array($0.sheets.values) }
            + bible.props.flatMap { $0.referenceImages + Array($0.sheets.values) }
        for entity in bible.locations {
            paths += entity.referenceImages + Array(entity.sheets.values) + entity.zones.flatMap(\.bibleAssets)
            if !entity.floorplan.isEmpty { paths.append(entity.floorplan) }
            if !entity.scene3d.panorama.isEmpty { paths.append(entity.scene3d.panorama) }
        }
        if !bible.look.lightingAnchor.isEmpty { paths.append(bible.look.lightingAnchor) }
        return Array(Set(paths)).sorted()
    }
}
