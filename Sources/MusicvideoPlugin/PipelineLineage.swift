import CryptoKit
import Foundation
import NexGenEngine

enum MusicvideoPipelineLineage {
    static let phases = [
        "analysis",
        "brief",
        "production_design",
        "treatment",
        "storyboard",
        "bible",
        "shotlist",
        "sanity",
        "frames",
        "render",
    ]

    enum LineageError: Swift.Error {
        case unknownPhase(String)
        case unreadableFile(String)
    }

    static func snapshot(
        phase: String,
        dataRoot: URL
    ) throws -> PhaseLineageSnapshot {
        guard phases.contains(phase) else {
            throw LineageError.unknownPhase(phase)
        }
        return PhaseLineageSnapshot(
            inputFingerprint: try fingerprint(
                selectors: inputSelectors(phase: phase, dataRoot: dataRoot),
                dynamicFiles: dynamicInputFiles(
                    phase: phase,
                    dataRoot: dataRoot
                ),
                dataRoot: dataRoot
            ),
            artifactFingerprint: try fingerprint(
                selectors: artifactSelectors(
                    phase: phase,
                    dataRoot: dataRoot
                ),
                dynamicFiles: dynamicArtifactFiles(
                    phase: phase,
                    dataRoot: dataRoot
                ),
                dataRoot: dataRoot
            )
        )
    }

    static func requireCurrent(phase: String, dataRoot: URL) throws {
        do {
            try PipelineLineageStore.requireCurrent(
                phase: phase,
                snapshot: try snapshot(phase: phase, dataRoot: dataRoot),
                dataRoot: dataRoot
            )
        } catch let blocked as GateBlocked {
            throw blocked
        } catch {
            throw GateBlocked(
                "Can't approve \"\(phase)\": its verified input lineage is unreadable "
                    + "(\(error)). Rebuild the phase."
            )
        }
    }

    private static func inputSelectors(
        phase: String,
        dataRoot: URL
    ) -> [String] {
        let analysisInputs = ["audio", "lyrics"]
        guard phase != "analysis" else { return analysisInputs }
        var selectors = analysisInputs + [
            PipelineLayout.projectFile,
            "analysis",
            "import",
            "intake.json",
        ]
        guard phase != "brief" else { return selectors }
        selectors.append(PipelineLayout.briefFile)
        guard phase != "production_design" else { return selectors }
        selectors.append("production_design/production_design.yaml")
        guard phase != "treatment" else { return selectors }
        selectors.append(PipelineLayout.treatmentCurrentFile)
        guard phase != "storyboard" else { return selectors }
        selectors.append(PipelineLayout.storyboardCurrentFile)
        guard phase != "bible" else { return selectors }
        selectors.append(PipelineLayout.bibleFile)
        guard phase != "shotlist" else { return selectors }
        if let version = latestShotlistVersion(dataRoot: dataRoot) {
            selectors.append(PipelineLayout.shotlistVersionFile(version))
        } else {
            selectors.append(PipelineLayout.shotlistVersionFile(0))
        }
        guard phase != "sanity" else { return selectors }
        selectors.append(PipelineLayout.sanityReportFile)
        guard phase != "frames" else { return selectors }
        selectors.append(PipelineLayout.framesDir)
        return selectors
    }

    private static func artifactSelectors(
        phase: String,
        dataRoot: URL
    ) -> [String] {
        switch phase {
        case "analysis":
            return []
        case "brief":
            return [PipelineLayout.projectFile, PipelineLayout.briefFile]
        case "production_design":
            return [
                "production_design/production_design.yaml",
                PipelineLayout.assetProofFile(
                    scope: "production_design"
                ),
            ]
        case "treatment":
            return [PipelineLayout.treatmentCurrentFile]
        case "storyboard":
            return [PipelineLayout.storyboardCurrentFile]
        case "bible":
            return [
                PipelineLayout.bibleFile,
                PipelineLayout.assetProofFile(scope: "bible"),
            ]
        case "shotlist":
            if let version = latestShotlistVersion(dataRoot: dataRoot) {
                return [PipelineLayout.shotlistVersionFile(version)]
            }
            return [PipelineLayout.shotlistVersionFile(0)]
        case "sanity":
            return [PipelineLayout.sanityReportFile]
        case "frames":
            return [PipelineLayout.framesDir]
        case "render":
            return [
                PipelineLayout.renderManifestFile(phase: "final"),
                PipelineLayout.renderProofFile(phase: "final"),
            ]
        default:
            return []
        }
    }

    private static func dynamicInputFiles(
        phase: String,
        dataRoot: URL
    ) -> [URL] {
        var urls: [URL] = []
        if phasesFrom("production_design").contains(phase) {
            urls += productionDesignReferences(dataRoot: dataRoot)
        }
        if phasesFrom("shotlist").contains(phase) {
            urls += bibleReferences(dataRoot: dataRoot)
            urls += shotlistReferences(dataRoot: dataRoot)
        }
        if phase == "render" {
            urls += frameImages(dataRoot: dataRoot)
        }
        return urls
    }

    private static func dynamicArtifactFiles(
        phase: String,
        dataRoot: URL
    ) -> [URL] {
        switch phase {
        case "analysis":
            var files = [
                AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot),
                AnalysisMeasurementProofStore.url(dataRoot: dataRoot),
            ].compactMap { $0 }.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            if let proof = try? AnalysisMeasurementProofStore.load(dataRoot: dataRoot),
               let sourcePath = proof.lyricsAlignment?.sourcePath,
               let source = projectFile(sourcePath, dataRoot: dataRoot) {
                files.append(source)
            }
            return files
        case "production_design":
            return productionDesignReferences(dataRoot: dataRoot)
        case "bible":
            return bibleReferences(dataRoot: dataRoot)
        case "shotlist":
            return shotlistReferences(dataRoot: dataRoot)
        case "frames":
            return frameImages(dataRoot: dataRoot)
        default:
            return []
        }
    }

    private static func phasesFrom(_ phase: String) -> Set<String> {
        guard let index = phases.firstIndex(of: phase) else { return [] }
        return Set(phases[index...])
    }

    private static func productionDesignReferences(dataRoot: URL) -> [URL] {
        guard let design = try? YAMLArtifactStore(dataRoot: dataRoot).load(
            ProductionDesign.self,
            at: "production_design/production_design.yaml"
        ) else { return [] }
        var paths = design.refs.map(\.path)
        if !design.lightingAnchor.isEmpty {
            paths.append(design.lightingAnchor)
        }
        return paths.compactMap {
            projectFile($0, dataRoot: dataRoot)
        }
    }

    private static func bibleReferences(dataRoot: URL) -> [URL] {
        guard let bible = try? loadBible(dataRoot: dataRoot) else { return [] }
        var paths: [String] = []
        for entity in bible.characters {
            paths += entity.referenceImages + Array(entity.sheets.values)
        }
        for entity in bible.ensembles {
            paths += entity.referenceImages + Array(entity.sheets.values)
        }
        for entity in bible.props {
            paths += entity.referenceImages + Array(entity.sheets.values)
        }
        for entity in bible.locations {
            paths += entity.referenceImages + Array(entity.sheets.values)
            paths += entity.zones.flatMap(\.bibleAssets)
            if !entity.floorplan.isEmpty {
                paths.append(entity.floorplan)
            }
            if !entity.scene3d.panorama.isEmpty {
                paths.append(entity.scene3d.panorama)
            }
        }
        if !bible.look.lightingAnchor.isEmpty {
            paths.append(bible.look.lightingAnchor)
        }
        return paths.compactMap {
            projectFile($0, dataRoot: dataRoot)
        }
    }

    private static func frameImages(dataRoot: URL) -> [URL] {
        guard let manifest = try? loadFramesManifest(dataRoot: dataRoot) else {
            return []
        }
        return manifest.shots
            .flatMap(\.frames)
            .compactMap { projectFile($0.path, dataRoot: dataRoot) }
    }

    private static func shotlistReferences(dataRoot: URL) -> [URL] {
        guard let shotlist = try? loadShotlist(dataRoot: dataRoot) else {
            return []
        }
        var paths = shotlist.shots.flatMap(\.referenceImageRefs)
        paths += shotlist.shots.compactMap {
            $0.sourceMode == .aiEnhanced ? $0.sourcePath : nil
        }
        return paths.compactMap {
            projectFile($0, dataRoot: dataRoot)
        }
    }

    private static func projectFile(
        _ rawPath: String,
        dataRoot: URL
    ) -> URL? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !NSString(string: path).isAbsolutePath,
              !path.split(separator: "/").contains("..") else {
            return nil
        }
        let home = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        for base in [dataRoot, FrameInventory.projectHome(of: dataRoot)] {
            let candidate = base.appendingPathComponent(path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard candidate.path == home.path
                    || candidate.path.hasPrefix(home.path + "/") else {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func fingerprint(
        selectors: [String],
        dynamicFiles: [URL],
        dataRoot: URL
    ) throws -> String {
        let home = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var hasher = SHA256()
        var selected: [String: URL] = [:]
        for selector in selectors {
            hasher.update(data: Data("selector:\(selector)\u{0}".utf8))
            let url = dataRoot.appendingPathComponent(selector)
            for file in regularFiles(at: url, inside: home) {
                selected[relativePath(file, home: home)] = file
            }
        }
        for file in dynamicFiles {
            let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path == home.path
                    || resolved.path.hasPrefix(home.path + "/") else {
                continue
            }
            selected[relativePath(resolved, home: home)] = resolved
        }
        for (path, url) in selected.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            do {
                hasher.update(data: Data(
                    try FileDigest.sha256(of: url).utf8
                ))
            } catch {
                throw LineageError.unreadableFile(path)
            }
            hasher.update(data: Data([0xff]))
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func regularFiles(
        at url: URL,
        inside home: URL
    ) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else { return [] }
        if !isDirectory.boolValue {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path == home.path
                    || resolved.path.hasPrefix(home.path + "/") else {
                return []
            }
            return [resolved]
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator {
            let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path == home.path
                    || resolved.path.hasPrefix(home.path + "/"),
                  (try? resolved.resourceValues(
                    forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true else {
                continue
            }
            files.append(resolved)
        }
        return files
    }

    private static func relativePath(_ url: URL, home: URL) -> String {
        let prefix = home.path + "/"
        return url.path.hasPrefix(prefix)
            ? String(url.path.dropFirst(prefix.count))
            : url.lastPathComponent
    }
}
