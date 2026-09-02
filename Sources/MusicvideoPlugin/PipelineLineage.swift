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
    static let executionInputPhases = Set([
        "analysis",
        "brief",
        "production_design",
        "treatment",
        "storyboard",
        "bible",
    ])

    enum LineageError: Swift.Error {
        case unknownPhase(String)
        case unreadableFile(String)
        case unsafeProjectPath(String)
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
                dynamicFiles: try dynamicInputFiles(
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
                dynamicFiles: try dynamicArtifactFiles(
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

    static func artifactPaths(
        phase: String,
        dataRoot: URL
    ) throws -> [String] {
        guard phases.contains(phase) else {
            throw LineageError.unknownPhase(phase)
        }
        let projectRoot = FrameInventory.projectHome(of: dataRoot).standardizedFileURL
        var selected: [String: URL] = [:]
        for selector in artifactSelectors(phase: phase, dataRoot: dataRoot) {
            let url = dataRoot.appendingPathComponent(selector)
            for file in try regularFiles(at: url, inside: projectRoot) {
                let path = try canonicalPath(
                    file,
                    dataRoot: dataRoot,
                    projectRoot: projectRoot
                )
                selected[path] = file
            }
        }
        for file in try dynamicArtifactFiles(phase: phase, dataRoot: dataRoot) {
            let path = try canonicalPath(
                file.standardizedFileURL,
                dataRoot: dataRoot,
                projectRoot: projectRoot
            )
            let safeFile: URL
            do {
                safeFile = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
            } catch {
                throw LineageError.unsafeProjectPath(path)
            }
            selected[path] = safeFile
        }
        return selected.keys.sorted()
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
        selectors.append(PipelineLayout.productionDesignFile)
        guard phase != "treatment" else { return selectors }
        selectors += treatmentSelectors(dataRoot: dataRoot)
        guard phase != "storyboard" else { return selectors }
        selectors += storyboardSelectors(dataRoot: dataRoot)
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
            return [
                PipelineLayout.projectFile,
                PipelineLayout.briefFile,
                AffectProfile.file,
            ]
        case "production_design":
            return [
                "production_design/production_design.yaml",
                PipelineLayout.assetProofFile(
                    scope: "production_design"
                ),
            ]
        case "treatment":
            return treatmentSelectors(dataRoot: dataRoot)
        case "storyboard":
            return storyboardSelectors(dataRoot: dataRoot)
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
            return [
                PipelineLayout.framesDir,
                PipelineLayout.renderManifestFile(phase: "frames"),
                RenderRecordPublicationV1.artifactPath(phase: "frames"),
                RenderShotProvenancePublicationV1.artifactPath(phase: "frames"),
            ]
        case "render":
            return [
                PipelineLayout.renderManifestFile(phase: "final"),
                PipelineLayout.renderProofFile(phase: "final"),
                PipelineLayout.renderRoutingProofFile(phase: "final"),
                RenderRecordPublicationV1.artifactPath(phase: "final"),
                RenderShotProvenancePublicationV1.artifactPath(phase: "final"),
            ]
        default:
            return []
        }
    }

    private static func treatmentSelectors(dataRoot: URL) -> [String] {
        var selectors = [PipelineLayout.treatmentCurrentFile]
        if let version = TreatmentStore.versions(dataRoot: dataRoot).last {
            selectors.append(PipelineLayout.treatmentVersionFile(version))
        }
        return selectors
    }

    private static func storyboardSelectors(dataRoot: URL) -> [String] {
        var selectors = [PipelineLayout.storyboardCurrentFile]
        let version = StoryboardStore.nextVersion(dataRoot: dataRoot) - 1
        if version > 0 {
            selectors.append(PipelineLayout.storyboardVersionFile(version))
        }
        return selectors
    }

    private static func dynamicInputFiles(
        phase: String,
        dataRoot: URL
    ) throws -> [URL] {
        var urls: [URL] = []
        if phasesFrom("production_design").contains(phase) {
            urls += try productionDesignReferences(dataRoot: dataRoot)
        }
        if phasesFrom("shotlist").contains(phase) {
            urls += try bibleReferences(dataRoot: dataRoot)
            urls += try shotlistReferences(dataRoot: dataRoot)
        }
        if phase == "render" {
            urls += try frameImages(dataRoot: dataRoot)
        }
        return urls
    }

    private static func dynamicArtifactFiles(
        phase: String,
        dataRoot: URL
    ) throws -> [URL] {
        switch phase {
        case "analysis":
            var files = [
                AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot),
                AnalysisMeasurementProofStore.url(dataRoot: dataRoot),
            ].compactMap { $0 }.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            if let proofURL = AnalysisMeasurementProofStore.url(dataRoot: dataRoot),
               FileManager.default.fileExists(atPath: proofURL.path) {
                let proof = try AnalysisMeasurementProofStore.load(dataRoot: dataRoot)
                if let sourcePath = proof.lyricsAlignment?.sourcePath {
                    files.append(try projectFile(sourcePath, dataRoot: dataRoot))
                }
            }
            return files
        case "production_design":
            return try productionDesignReferences(dataRoot: dataRoot)
        case "bible":
            return try bibleReferences(dataRoot: dataRoot)
        case "shotlist":
            return try shotlistReferences(dataRoot: dataRoot)
        case "frames":
            return try frameImages(dataRoot: dataRoot)
                + renderRecordArtifacts(phase: "frames", dataRoot: dataRoot)
        case "render":
            return try renderRecordArtifacts(phase: "final", dataRoot: dataRoot)
        default:
            return []
        }
    }

    private static func phasesFrom(_ phase: String) -> Set<String> {
        guard let index = phases.firstIndex(of: phase) else { return [] }
        return Set(phases[index...])
    }

    private static func productionDesignReferences(dataRoot: URL) throws -> [URL] {
        let artifactURL = PipelineLayout.url(
            PipelineLayout.productionDesignFile,
            in: dataRoot
        )
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            return []
        }
        let design = try YAMLArtifactStore(dataRoot: dataRoot).load(
            ProductionDesign.self,
            at: "production_design/production_design.yaml"
        )
        var paths = design.refs.map(\.path)
        if !design.lightingAnchor.isEmpty {
            paths.append(design.lightingAnchor)
        }
        return try paths.map {
            try projectFile($0, dataRoot: dataRoot)
        }
    }

    private static func bibleReferences(dataRoot: URL) throws -> [URL] {
        let artifactURL = PipelineLayout.url(PipelineLayout.bibleFile, in: dataRoot)
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            return []
        }
        guard let bible = try loadBible(dataRoot: dataRoot) else {
            throw LineageError.unreadableFile(PipelineLayout.bibleFile)
        }
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
        return try paths.map {
            try projectFile($0, dataRoot: dataRoot)
        }
    }

    private static func frameImages(dataRoot: URL) throws -> [URL] {
        let artifactURL = PipelineLayout.url(
            PipelineLayout.framesManifestFile,
            in: dataRoot
        )
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            return []
        }
        let manifest = try loadFramesManifest(dataRoot: dataRoot)
        return try manifest.shots
            .flatMap(\.frames)
            .map { try projectFile($0.path, dataRoot: dataRoot) }
    }

    private static func renderRecordArtifacts(
        phase: String,
        dataRoot: URL
    ) throws -> [URL] {
        let publicationPath = RenderShotProvenancePublicationV1.artifactPath(
            phase: phase
        )
        let publicationURL = PipelineLayout.url(publicationPath, in: dataRoot)
        guard FileManager.default.fileExists(atPath: publicationURL.path) else {
            return []
        }
        let publicationData: Data
        let publication: RenderShotProvenancePublicationV1
        do {
            publicationData = try Data(contentsOf: publicationURL)
            publication = try JSONDecoder().decode(
                RenderShotProvenancePublicationV1.self,
                from: publicationData
            )
        } catch {
            throw LineageError.unreadableFile(publicationPath)
        }
        guard (try? RenderShotProvenanceValidatorV1.validate(publication)) != nil,
              publication.phase == phase else {
            throw LineageError.unreadableFile(publicationPath)
        }
        var files: [URL] = [publicationURL]
        for (shotID, artifact) in publication.proofs.sorted(by: {
            $0.key < $1.key
        }) {
            let proofURL = try projectFile(artifact.path, dataRoot: dataRoot)
            let proofData: Data
            let proof: RenderShotProvenanceProofV1
            do {
                proofData = try Data(contentsOf: proofURL)
                guard FileDigest.sha256(of: proofData) == artifact.sha256 else {
                    throw LineageError.unreadableFile(artifact.path)
                }
                proof = try JSONDecoder().decode(
                    RenderShotProvenanceProofV1.self,
                    from: proofData
                )
                try RenderShotProvenanceValidatorV1.validate(
                    proof,
                    artifactPath: artifact.path,
                    artifactSHA256: artifact.sha256
                )
            } catch let error as LineageError {
                throw error
            } catch {
                throw LineageError.unreadableFile(artifact.path)
            }
            guard proof.project == publication.project,
                  proof.phase == phase,
                  proof.shotID == shotID else {
                throw LineageError.unreadableFile(artifact.path)
            }
            files.append(proofURL)
            for dependency in proof.dependencies {
                let dependencyURL = try projectFile(
                    dependency.path,
                    dataRoot: dataRoot
                )
                do {
                    guard try FileDigest.sha256(of: dependencyURL)
                            == dependency.sha256 else {
                        throw LineageError.unreadableFile(dependency.path)
                    }
                } catch let error as LineageError {
                    throw error
                } catch {
                    throw LineageError.unreadableFile(dependency.path)
                }
                files.append(dependencyURL)
            }
            for output in proof.outputs {
                let outputURL = try projectFile(
                    output.path,
                    dataRoot: dataRoot
                )
                do {
                    guard try FileDigest.sha256(of: outputURL)
                            == output.sha256 else {
                        throw LineageError.unreadableFile(output.path)
                    }
                } catch let error as LineageError {
                    throw error
                } catch {
                    throw LineageError.unreadableFile(output.path)
                }
                files.append(outputURL)
            }
        }
        return files
    }

    private static func shotlistReferences(dataRoot: URL) throws -> [URL] {
        guard let shotlist = try loadShotlist(dataRoot: dataRoot) else { return [] }
        var paths = shotlist.shots.flatMap(\.referenceImageRefs)
        paths += shotlist.shots.compactMap {
            $0.sourceMode == .aiEnhanced ? $0.sourcePath : nil
        }
        return try paths.map {
            try projectFile($0, dataRoot: dataRoot)
        }
    }

    private static func projectFile(
        _ rawPath: String,
        dataRoot: URL
    ) throws -> URL {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              path == rawPath,
              !NSString(string: path).isAbsolutePath,
              !path.split(separator: "/").contains("..") else {
            throw LineageError.unsafeProjectPath(rawPath)
        }
        do {
            return try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        } catch {
            throw LineageError.unsafeProjectPath(path)
        }
    }

    private static func fingerprint(
        selectors: [String],
        dynamicFiles: [URL],
        dataRoot: URL
    ) throws -> String {
        let home = FrameInventory.projectHome(of: dataRoot).standardizedFileURL
        var hasher = SHA256()
        var selected: [String: URL] = [:]
        for selector in selectors {
            hasher.update(data: Data("selector:\(selector)\u{0}".utf8))
            let url = dataRoot.appendingPathComponent(selector)
            for file in try regularFiles(at: url, inside: home) {
                selected[try canonicalPath(
                    file,
                    dataRoot: dataRoot,
                    projectRoot: home
                )] = file
            }
        }
        for file in dynamicFiles {
            let canonical = try canonicalPath(
                file.standardizedFileURL,
                dataRoot: dataRoot,
                projectRoot: home
            )
            do {
                selected[canonical] = try ProjectLocalFile.resolve(
                    canonical,
                    dataRoot: dataRoot
                )
            } catch {
                throw LineageError.unsafeProjectPath(canonical)
            }
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
    ) throws -> [URL] {
        let candidate = url.standardizedFileURL
        guard candidate.path == home.path
                || candidate.path.hasPrefix(home.path + "/") else {
            throw LineageError.unsafeProjectPath(candidate.path)
        }
        try requireNoSymbolicLink(candidate, inside: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ) else { return [] }
        if !isDirectory.boolValue {
            let values = try candidate.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw LineageError.unsafeProjectPath(candidate.path)
            }
            return [candidate]
        }
        var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: candidate,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator {
            let standardized = file.standardizedFileURL
            guard standardized.path.hasPrefix(home.path + "/") else {
                throw LineageError.unsafeProjectPath(standardized.path)
            }
            try requireNoSymbolicLink(standardized, inside: home)
            let values = try standardized.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw LineageError.unsafeProjectPath(standardized.path)
            }
            guard values.isRegularFile == true else {
                continue
            }
            files.append(standardized)
        }
        if enumerationError != nil {
            throw LineageError.unreadableFile(candidate.path)
        }
        return files
    }

    private static func requireNoSymbolicLink(_ url: URL, inside home: URL) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(
            atPath: home.path
        )) == nil else {
            throw LineageError.unsafeProjectPath(home.path)
        }
        let suffix = url.path.dropFirst(home.path.count)
        var current = home
        for component in suffix.split(separator: "/") {
            current.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(
                atPath: current.path
            )) != nil {
                throw LineageError.unsafeProjectPath(current.path)
            }
        }
    }

    private static func relativePath(_ url: URL, home: URL) -> String {
        let prefix = home.path + "/"
        return url.path.hasPrefix(prefix)
            ? String(url.path.dropFirst(prefix.count))
            : url.lastPathComponent
    }

    private static func canonicalPath(
        _ url: URL,
        dataRoot: URL,
        projectRoot: URL
    ) throws -> String {
        let file = url.standardizedFileURL
        let resolvedDataRoot = dataRoot.standardizedFileURL
        if file.path.hasPrefix(resolvedDataRoot.path + "/") {
            return String(file.path.dropFirst(resolvedDataRoot.path.count + 1))
        }
        guard file.path.hasPrefix(projectRoot.path + "/") else {
            throw LineageError.unsafeProjectPath(file.path)
        }
        return relativePath(file, home: projectRoot)
    }
}
