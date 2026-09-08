import Foundation

public enum ProductionStyleStoreV1 {
    public static let lineageID = "production-style.v1"
    private static let designPath = "production_design/production_design.yaml"

    public static func load(dataRoot: URL) throws -> ResolvedProductionStyleV1? {
        let target = dataRoot.appendingPathComponent(ResolvedProductionStyleV1.relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
                throw ProjectLocalFileError.symbolicLink(ResolvedProductionStyleV1.relativePath)
            }
            if try PipelineLineageStore.loadIfPresent(dataRoot: dataRoot)?.phases[lineageID] != nil {
                try PipelineLineageStore.requireCurrent(phase: lineageID, snapshot: snapshot(dataRoot: dataRoot), dataRoot: dataRoot)
            }
            return nil
        }
        let url = try ProjectLocalFile.resolve(ResolvedProductionStyleV1.relativePath, dataRoot: dataRoot)
        let style = try JSONDecoder().decode(ResolvedProductionStyleV1.self, from: Data(contentsOf: url))
        try style.validate(catalog: EngineProductionKnowledgeResourcesV1.loadCatalog())
        try PipelineLineageStore.requireCurrent(phase: lineageID, snapshot: snapshot(dataRoot: dataRoot), dataRoot: dataRoot)
        return style
    }

    public static func snapshot(dataRoot: URL) throws -> PhaseLineageSnapshot {
        let inputs = try [PipelineLayout.projectFile, PipelineLayout.briefFile, designPath].map { path in
            path + ":" + (try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
        }.joined(separator: "\n")
        let target = dataRoot.appendingPathComponent(ResolvedProductionStyleV1.relativePath)
        let styleHash: String
        if FileManager.default.fileExists(atPath: target.path) {
            styleHash = try FileDigest.sha256(of: ProjectLocalFile.resolve(ResolvedProductionStyleV1.relativePath, dataRoot: dataRoot))
        } else {
            styleHash = "none"
        }
        return PhaseLineageSnapshot(inputFingerprint: FileDigest.sha256(of: Data(inputs.utf8)),
                                    artifactFingerprint: styleHash)
    }

    public static func write(design: ProductionDesign, selection: ProductionStyleSelectionV1?,
                             clearStyle: Bool, dataRoot: URL) throws {
        _ = try ProjectLocalFile.resolve(PipelineLayout.projectFile, dataRoot: dataRoot)
        guard !clearStyle || selection == nil else {
            throw GateBlocked("Choose a style or clear it, not both.")
        }
        let priorStyle = selection == nil && !clearStyle ? try load(dataRoot: dataRoot) : nil
        let hasTrace = try PipelineLineageStore.loadIfPresent(dataRoot: dataRoot)?.phases[lineageID] != nil
        let style = try selection.map {
            try ResolvedProductionStyleV1.resolve($0, catalog: EngineProductionKnowledgeResourcesV1.loadCatalog())
        } ?? (clearStyle ? nil : priorStyle)
        let paths = [designPath, ResolvedProductionStyleV1.relativePath, PipelineLayout.lineageFile]
        let urls = try paths.map { path -> URL in
            let url = dataRoot.appendingPathComponent(path).standardizedFileURL
            guard url.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath().appendingPathComponent(path).standardizedFileURL else {
                throw ProjectLocalFileError.symbolicLink(path)
            }
            return url
        }
        let previous = try urls.map { url -> Data? in
            FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        }
        do {
            try FileManager.default.createDirectory(at: urls[0].deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(YAMLCoding.encode(design).utf8).write(to: urls[0], options: .atomic)
            if let style {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                try encoder.encode(style).write(to: urls[1], options: .atomic)
            } else if FileManager.default.fileExists(atPath: urls[1].path) {
                try FileManager.default.removeItem(at: urls[1])
            }
            if style != nil || clearStyle || hasTrace {
                try PipelineLineageStore.record(phase: lineageID, snapshot: snapshot(dataRoot: dataRoot), dataRoot: dataRoot)
            }
        } catch {
            let failure = error
            var rollbackErrors: [String] = []
            for (url, data) in zip(urls, previous) {
                do {
                    if let data { try data.write(to: url, options: .atomic) }
                    else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } catch { rollbackErrors.append(error.localizedDescription) }
            }
            if !rollbackErrors.isEmpty {
                throw GateBlocked("Production Design rollback failed: " + rollbackErrors.joined(separator: "; "))
            }
            throw failure
        }
    }
}
