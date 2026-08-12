import CryptoKit
import Foundation
import NexGenEngine

/// CI-only real app and external-pack analysis against a private content-addressed fixture.
@MainActor
enum ExampleAudioAnalysisSelfTest {
    private static let manifestSchema = "nexgenvideo.example-fixtures/v1"
    private static let reportSchema = "nexgenvideo.example-analysis-report/v2"

    private struct Configuration {
        let packURL: URL
        let fixtureRoot: URL
        let manifestURL: URL
        let fixtureReference: String
        let datasetID: String
        let reportDirectory: URL
        let commit: String
        let runID: String
        let runAttempt: String

        init?(environment: [String: String]) throws {
            guard let pack = environment["NGV_EXAMPLE_ANALYSIS_PACK"], !pack.isEmpty else {
                return nil
            }
            func required(_ key: String) throws -> String {
                guard let value = environment[key], !value.isEmpty else {
                    throw Failure("missing required environment value: \(key)")
                }
                return value
            }
            let reference = try required("NGV_EXAMPLE_REGISTRY_REFERENCE")
            guard Self.isImmutableRegistryReference(reference) else {
                throw Failure("NGV_EXAMPLE_REGISTRY_REFERENCE must contain an exact sha256 digest")
            }
            packURL = URL(fileURLWithPath: pack)
            fixtureRoot = URL(fileURLWithPath: try required("NGV_EXAMPLE_FIXTURE_ROOT"), isDirectory: true)
            manifestURL = URL(fileURLWithPath: try required("NGV_EXAMPLE_FIXTURE_MANIFEST"))
            fixtureReference = reference
            datasetID = try required("NGV_EXAMPLE_DATASET")
            reportDirectory = URL(
                fileURLWithPath: try required("NGV_EXAMPLE_REPORT_DIR"),
                isDirectory: true
            )
            commit = try required("NGV_GIT_COMMIT")
            runID = environment["GITHUB_RUN_ID"] ?? "local"
            runAttempt = environment["GITHUB_RUN_ATTEMPT"] ?? "1"
        }

        private static func isImmutableRegistryReference(_ reference: String) -> Bool {
            let parts = reference.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].hasPrefix("ghcr.io/"),
                  parts[1].hasPrefix("sha256:") else { return false }
            let digest = parts[1].dropFirst("sha256:".count)
            return digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) }
        }
    }

    private struct FixtureManifest: Decodable {
        let schema: String
        let treeSHA256: String
        let datasets: [FixtureDataset]

        enum CodingKeys: String, CodingKey {
            case schema, datasets
            case treeSHA256 = "tree_sha256"
        }
    }

    private struct FixtureDataset: Decodable {
        let id: String
        let files: [FixtureFile]
        let expectations: FixtureExpectations?
    }

    private struct FixtureFile: Codable {
        let kind: String
        let path: String
        let sha256: String
        let size: Int
    }

    private struct FixtureExpectations: Codable {
        let audio: AudioExpectation
    }

    private struct AudioExpectation: Codable {
        let path: String
        let durationS: Double
        let durationToleranceS: Double
        let bpm: Double
        let bpmTolerance: Double
        let expectBoundaryReduction: Bool
        let sectionBoundariesS: [Double]
        let sectionBoundaryToleranceS: Double

        enum CodingKeys: String, CodingKey {
            case path, bpm
            case durationS = "duration_s"
            case durationToleranceS = "duration_tolerance_s"
            case bpmTolerance = "bpm_tolerance"
            case expectBoundaryReduction = "expect_boundary_reduction"
            case sectionBoundariesS = "section_boundaries_s"
            case sectionBoundaryToleranceS = "section_boundary_tolerance_s"
        }
    }

    private struct AnalysisSummary: Encodable {
        let artifact: String
        let sha256: String
        let durationS: Double
        let bpm: Double
        let beatCount: Int
        let downbeatCount: Int
        let sectionCount: Int
        let structureStatus: String
        let structureMethod: String
        let segmentCount: Int
        let phraseCount: Int
        let candidateBoundaryCount: Int
        let acceptedBoundaryCount: Int
        let sectionBoundaryTimesS: [Double]

        enum CodingKeys: String, CodingKey {
            case artifact, sha256, bpm
            case durationS = "duration_s"
            case beatCount = "beat_count"
            case downbeatCount = "downbeat_count"
            case sectionCount = "section_count"
            case structureStatus = "structure_status"
            case structureMethod = "structure_method"
            case segmentCount = "segment_count"
            case phraseCount = "phrase_count"
            case candidateBoundaryCount = "candidate_boundary_count"
            case acceptedBoundaryCount = "accepted_boundary_count"
            case sectionBoundaryTimesS = "section_boundary_times_s"
        }
    }

    private struct Verification: Encodable {
        let fixtureIntegrity: String
        let artifactWriteGate: String
        let immutableFixtureReference: String
        let optionalAudioML: OptionalAudioML

        enum CodingKeys: String, CodingKey {
            case fixtureIntegrity = "fixture_integrity"
            case artifactWriteGate = "artifact_write_gate"
            case immutableFixtureReference = "immutable_fixture_reference"
            case optionalAudioML = "optional_audio_ml"
        }
    }

    private struct OptionalAudioML: Encodable {
        let transcription: String
        let stemSeparation: String
        let beatGrid: String
        let chordRecognition: String

        var allUnavailable: Bool {
            [transcription, stemSeparation, beatGrid, chordRecognition]
                .allSatisfy { $0 == "unavailable" }
        }

        enum CodingKeys: String, CodingKey {
            case transcription
            case stemSeparation = "stem_separation"
            case beatGrid = "beat_grid"
            case chordRecognition = "chord_recognition"
        }
    }

    private struct Report: Encodable {
        let schema: String
        let fixtureReference: String
        let fixtureTreeSHA256: String
        let dataset: String
        let sourceFiles: [FixtureFile]
        let expectations: FixtureExpectations
        let packVersion: String
        let packTreeSHA256: String
        let commit: String
        let runID: String
        let runAttempt: String
        let analysis: AnalysisSummary
        let verification: Verification

        enum CodingKeys: String, CodingKey {
            case schema, dataset, expectations, commit, analysis, verification
            case fixtureReference = "fixture_reference"
            case fixtureTreeSHA256 = "fixture_tree_sha256"
            case sourceFiles = "source_files"
            case packVersion = "pack_version"
            case packTreeSHA256 = "pack_tree_sha256"
            case runID = "run_id"
            case runAttempt = "run_attempt"
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func runIfRequested() {
        do {
            guard let configuration = try Configuration(
                environment: ProcessInfo.processInfo.environment
            ) else { return }
            let summary = try run(configuration)
            let boundaries = summary.sectionBoundaryTimesS
                .map { String(format: "%.3f", $0) }
                .joined(separator: ",")
            let message = "SELFTEST_EXAMPLE_ANALYSIS_OK dataset=\(configuration.datasetID) "
                + "duration=\(String(format: "%.3f", summary.durationS)) "
                + "bpm=\(String(format: "%.3f", summary.bpm)) "
                + "beats=\(summary.beatCount) downbeats=\(summary.downbeatCount) "
                + "structure_status=\(summary.structureStatus) "
                + "structure_method=\(summary.structureMethod) "
                + "segments=\(summary.segmentCount) phrases=\(summary.phraseCount) "
                + "candidate_boundaries=\(summary.candidateBoundaryCount) "
                + "accepted_boundaries=\(summary.acceptedBoundaryCount) "
                + "sections=\(summary.sectionCount) boundaries_s=\(boundaries)\n"
            FileHandle.standardOutput.write(Data(message.utf8))
            exit(0)
        } catch {
            let detail = (error as? Failure)?.message
                ?? String(reflecting: type(of: error))
            FileHandle.standardError.write(
                Data("SELFTEST_EXAMPLE_ANALYSIS_FAIL \(detail)\n".utf8)
            )
            exit(1)
        }
    }

    private static func run(_ configuration: Configuration) throws -> AnalysisSummary {
        let manifest = try JSONDecoder().decode(
            FixtureManifest.self,
            from: Data(contentsOf: configuration.manifestURL)
        )
        guard manifest.schema == manifestSchema,
              manifest.treeSHA256.count == 64,
              manifest.treeSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw Failure("fixture manifest identity is invalid")
        }
        guard let dataset = manifest.datasets.first(where: { $0.id == configuration.datasetID }) else {
            throw Failure("fixture dataset not found: \(configuration.datasetID)")
        }
        guard manifest.datasets.filter({ $0.id == configuration.datasetID }).count == 1 else {
            throw Failure("fixture dataset is duplicated: \(configuration.datasetID)")
        }
        let verifiedFiles = try verifyFiles(
            dataset.files,
            datasetID: dataset.id,
            root: configuration.fixtureRoot
        )
        let audioFiles = verifiedFiles.filter { $0.entry.kind == "audio" }
        let lyricsFiles = verifiedFiles.filter { $0.entry.kind == "lyrics" }
        guard audioFiles.count == 1, lyricsFiles.count <= 1 else {
            throw Failure("dataset must contain exactly one audio file and at most one lyrics file")
        }
        guard let expectations = dataset.expectations else {
            throw Failure("dataset has no independent audio expectations")
        }
        guard expectations.audio.path == audioFiles[0].entry.path else {
            throw Failure("audio expectations refer to a different fixture file")
        }

        let record = PluginLoader.load(at: configuration.packURL)
        guard record.state == .loaded, record.id == "musicvideo" else {
            throw Failure(record.incompatibility?.reason ?? "musicvideo pack did not load")
        }
        let packTreeSHA256 = try directoryTreeSHA256(configuration.packURL)
        let registry = PackCatalog.registry(activePack: record.id)
        let optionalAudioML = OptionalAudioML(
            transcription: registry.transcriber == nil ? "unavailable" : "available",
            stemSeparation: registry.stemSeparator == nil ? "unavailable" : "available",
            beatGrid: registry.beatDetector == nil ? "unavailable" : "available",
            chordRecognition: registry.chordRecognizer == nil ? "unavailable" : "available"
        )
        guard optionalAudioML.allUnavailable else {
            throw Failure("decoder-only self-test registry unexpectedly contains optional audio ML")
        }
        registry.registerAudioDecoder(AVFoundationAudioDecoder())
        registry.registerMusicUnderstandingAnalyzer(AppleMusicUnderstandingAnalyzer())
        guard let runner = registry.phases["analysis"],
              let artifactGate = registry.artifactWriteRequirements["analysis"] else {
            throw Failure("loaded musicvideo pack has no complete analysis contract")
        }

        let projectHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-example-analysis-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectHome) }
        let dataRoot = try ProjectScaffold.initProject(
            home: projectHome,
            name: "Example Analysis \(configuration.datasetID)",
            mode: .beat,
            extraDirs: registry.projectDirs
        )
        try copy(audioFiles[0].url, to: dataRoot.appendingPathComponent("audio", isDirectory: true))
        if let lyrics = lyricsFiles.first {
            try copy(lyrics.url, to: dataRoot.appendingPathComponent("lyrics", isDirectory: true))
        }
        for step in registry.deterministicSteps where step.phase == "analysis" {
            try step.run(dataRoot)
        }
        try executeRunner(runner, dataRoot: dataRoot)
        try artifactGate(dataRoot)

        guard let artifactURL = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot),
              FileManager.default.fileExists(atPath: artifactURL.path) else {
            throw Failure("analysis runner did not write its canonical artifact")
        }
        let artifactData = try Data(contentsOf: artifactURL)
        guard let object = try JSONSerialization.jsonObject(with: artifactData) as? [String: Any],
              let duration = number(object["duration_s"]),
              let bpm = number(object["bpm"]),
              let beats = object["beats"] as? [Any],
              let downbeats = object["downbeats"] as? [Any],
              let sections = object["sections"] as? [[String: Any]],
              let diagnostics = object["stage_diagnostics"] as? [[String: Any]],
              let resolution = object["structure_resolution"] as? [String: Any],
              let status = resolution["status"] as? String,
              let method = resolution["method"] as? String,
              let hierarchy = resolution["hierarchy"] as? [String: Any],
              let hierarchySections = hierarchy["sections"] as? [[String: Any]],
              let hierarchySegments = hierarchy["segments"] as? [[String: Any]],
              let hierarchyPhrases = hierarchy["phrases"] as? [[String: Any]],
              let candidateCount = integer(resolution["candidate_boundary_count"]),
              let acceptedCount = integer(resolution["accepted_boundary_count"]) else {
            throw Failure("canonical analysis is missing its measured summary or resolution record")
        }
        guard status == "resolved",
              method == "music_understanding_hierarchy",
              hierarchy["source"] as? String == "apple_music_understanding",
              hierarchySections.count == sections.count,
              !hierarchySegments.isEmpty,
              !hierarchyPhrases.isEmpty else {
            throw Failure("canonical structure is not usable: \(status)")
        }
        guard sections.count == acceptedCount + 1 else {
            throw Failure("canonical section count does not match accepted boundary evidence")
        }
        guard diagnostic(diagnostics, stage: "native_dsp", status: "succeeded"),
              diagnostic(diagnostics, stage: "music_understanding", status: "succeeded"),
              diagnostic(diagnostics, stage: "stem_separation", status: "unavailable"),
              diagnostic(diagnostics, stage: "neural_beat_grid", status: "not_applicable"),
              diagnostic(diagnostics, stage: "chord_recognition", status: "unavailable") else {
            throw Failure("analysis did not exercise system hierarchy with its declared fallbacks")
        }
        if !lyricsFiles.isEmpty {
            guard diagnostic(diagnostics, stage: "lyrics_input", status: "succeeded"),
                  diagnostic(diagnostics, stage: "lyrics_alignment", status: "unavailable") else {
                throw Failure("lyrics fallback diagnostics do not match the decoder-only contract")
            }
        }
        guard abs(duration - expectations.audio.durationS) <= expectations.audio.durationToleranceS else {
            throw Failure(
                "duration \(duration)s is outside the fixture expectation "
                    + "\(expectations.audio.durationS)±\(expectations.audio.durationToleranceS)s"
            )
        }
        guard abs(bpm - expectations.audio.bpm) <= expectations.audio.bpmTolerance else {
            throw Failure(
                "tempo \(bpm) BPM is outside the fixture expectation "
                    + "\(expectations.audio.bpm)±\(expectations.audio.bpmTolerance) BPM"
            )
        }
        if expectations.audio.expectBoundaryReduction {
            guard acceptedCount > 0, candidateCount > acceptedCount else {
                throw Failure(
                    "fixture expected non-empty raw boundary reduction, but candidates="
                        + "\(candidateCount) accepted=\(acceptedCount)"
                )
            }
        }
        guard object["song_path"] as? String == "audio/\(audioFiles[0].url.lastPathComponent)" else {
            throw Failure("analysis does not preserve the original source filename project-locally")
        }
        let sectionBoundaryTimes = sections.dropFirst().compactMap {
            number($0["start"])
        }
        guard sectionBoundaryTimes.count == acceptedCount else {
            throw Failure("canonical boundary summary is incomplete")
        }
        guard sectionBoundaryTimes.count == expectations.audio.sectionBoundariesS.count else {
            throw Failure(
                "canonical boundary count \(sectionBoundaryTimes.count) does not match the independent "
                    + "expectation \(expectations.audio.sectionBoundariesS.count)"
            )
        }
        for (actual, expected) in zip(sectionBoundaryTimes, expectations.audio.sectionBoundariesS) {
            guard abs(actual - expected) <= expectations.audio.sectionBoundaryToleranceS else {
                throw Failure(
                    "section boundary \(actual)s is outside the independent expectation "
                        + "\(expected)±\(expectations.audio.sectionBoundaryToleranceS)s"
                )
            }
        }
        let artifactText = String(decoding: artifactData, as: UTF8.self)
        guard ![configuration.fixtureRoot.path, projectHome.path].contains(where: {
            artifactText.contains($0)
        }) else {
            throw Failure("analysis artifact leaked a runner-local path")
        }

        let summary = AnalysisSummary(
            artifact: "analysis.json",
            sha256: try FileDigest.sha256(of: artifactURL),
            durationS: duration,
            bpm: bpm,
            beatCount: beats.count,
            downbeatCount: downbeats.count,
            sectionCount: sections.count,
            structureStatus: status,
            structureMethod: method,
            segmentCount: hierarchySegments.count,
            phraseCount: hierarchyPhrases.count,
            candidateBoundaryCount: candidateCount,
            acceptedBoundaryCount: acceptedCount,
            sectionBoundaryTimesS: sectionBoundaryTimes
        )
        try writeReport(
            configuration: configuration,
            manifest: manifest,
            dataset: dataset,
            expectations: expectations,
            packVersion: record.version,
            packTreeSHA256: packTreeSHA256,
            optionalAudioML: optionalAudioML,
            artifactData: artifactData,
            summary: summary
        )
        return summary
    }

    private static func verifyFiles(
        _ files: [FixtureFile],
        datasetID: String,
        root: URL
    ) throws -> [(entry: FixtureFile, url: URL)] {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var paths = Set<String>()
        return try files.enumerated().map { index, entry in
            let reference = "dataset=\(datasetID) entry=\(index) digest=\(entry.sha256.prefix(8))"
            guard paths.insert(entry.path).inserted,
                  isSafeRelativePath(entry.path),
                  entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isHexDigit }),
                  entry.size >= 0 else {
                throw Failure("invalid or duplicate fixture manifest entry: \(reference)")
            }
            let url = root.appendingPathComponent(entry.path)
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(resolvedRoot.path + "/"),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize == entry.size,
                  try FileDigest.sha256(of: url) == entry.sha256 else {
                throw Failure("fixture integrity check failed: \(reference)")
            }
            return (entry, url)
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        let components = NSString(string: path).pathComponents
        return !path.isEmpty
            && !NSString(string: path).isAbsolutePath
            && !components.contains("..")
            && !components.contains(".")
    }

    private static func copy(_ source: URL, to directory: URL) throws {
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure("project fixture destination already exists")
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func directoryTreeSHA256(_ root: URL) throws -> String {
        let manager = FileManager.default
        let canonicalRoot = root.standardizedFileURL
        guard let enumerator = manager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            throw Failure("pack bundle cannot be enumerated")
        }
        var records: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            let prefix = canonicalRoot.path + "/"
            guard url.path.hasPrefix(prefix) else {
                throw Failure("pack bundle enumeration escaped its root")
            }
            let relativePath = String(url.path.dropFirst(prefix.count))
            if values.isSymbolicLink == true {
                let destination = try manager.destinationOfSymbolicLink(atPath: url.path)
                records.append("\(relativePath)\0symlink\0\(destination)\n")
            } else if values.isRegularFile == true {
                guard let size = values.fileSize else {
                    throw Failure("pack bundle file size is unavailable: \(relativePath)")
                }
                records.append(
                    "\(relativePath)\0file\0\(size)\0\(try FileDigest.sha256(of: url))\n"
                )
            }
        }
        let digest = SHA256.hash(data: Data(records.sorted().joined().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        return value as? Double
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return value as? Int }
        let double = number.doubleValue
        guard double.rounded() == double else { return nil }
        return number.intValue
    }

    private static func diagnostic(
        _ diagnostics: [[String: Any]],
        stage: String,
        status: String
    ) -> Bool {
        diagnostics.contains {
            $0["stage"] as? String == stage && $0["status"] as? String == status
        }
    }

    private static func executeRunner(
        _ runner: @escaping EngineRegistry.PhaseRunner,
        dataRoot: URL
    ) throws {
        let completion = SelfTestRunnerCompletion()
        let thread = Thread {
            do {
                try runner(dataRoot)
                completion.finish(.success(()))
            } catch {
                completion.finish(.failure(error))
            }
        }
        thread.name = "NexGenVideo example analysis"
        thread.qualityOfService = .userInitiated
        thread.start()
        while !completion.isFinished {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.05)
            )
        }
        try completion.result().get()
    }

    private static func writeReport(
        configuration: Configuration,
        manifest: FixtureManifest,
        dataset: FixtureDataset,
        expectations: FixtureExpectations,
        packVersion: String,
        packTreeSHA256: String,
        optionalAudioML: OptionalAudioML,
        artifactData: Data,
        summary: AnalysisSummary
    ) throws {
        try FileManager.default.createDirectory(
            at: configuration.reportDirectory,
            withIntermediateDirectories: true
        )
        try artifactData.write(
            to: configuration.reportDirectory.appendingPathComponent("analysis.json"),
            options: .atomic
        )
        let report = Report(
            schema: reportSchema,
            fixtureReference: configuration.fixtureReference,
            fixtureTreeSHA256: manifest.treeSHA256,
            dataset: dataset.id,
            sourceFiles: dataset.files,
            expectations: expectations,
            packVersion: packVersion,
            packTreeSHA256: packTreeSHA256,
            commit: configuration.commit,
            runID: configuration.runID,
            runAttempt: configuration.runAttempt,
            analysis: summary,
            verification: Verification(
                fixtureIntegrity: "passed",
                artifactWriteGate: "passed",
                immutableFixtureReference: "passed",
                optionalAudioML: optionalAudioML
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(report)
        data.append(0x0A)
        try data.write(
            to: configuration.reportDirectory.appendingPathComponent("provenance.json"),
            options: .atomic
        )
    }
}

private final class SelfTestRunnerCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Void, any Error>?

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored != nil
    }

    func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard stored == nil else { return }
        stored = result
    }

    func result() -> Result<Void, any Error> {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? .failure(CocoaError(.coderInvalidValue))
    }
}
