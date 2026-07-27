import Foundation

/// Port of `sanity/models.py::Level`.
public enum Level: String, Codable, Sendable, Equatable {
    case info
    case warn
    case error
}

/// One sanity-check result. Port of `sanity/models.py::Finding`.
public struct Finding: Codable, Sendable, Equatable {
    public var level: Level
    public var code: String
    public var shotId: String?
    public var message: String

    public init(level: Level, code: String, shotId: String? = nil, message: String) {
        self.level = level
        self.code = code
        self.shotId = shotId
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case code
        case shotId = "shot_id"
        case message
    }
}

/// The aggregate result of an audit run. Port of `sanity/models.py::SanityReport`.
public struct SanityReport: Codable, Sendable, Equatable {
    public var project: String
    public var findings: [Finding]

    public init(project: String, findings: [Finding] = []) {
        self.project = project
        self.findings = findings
    }

    /// Port of `SanityReport.errors`.
    public var errors: [Finding] { findings.filter { $0.level == .error } }

    /// Port of `SanityReport.warnings`.
    public var warnings: [Finding] { findings.filter { $0.level == .warn } }

    /// Port of `SanityReport.is_clean`.
    public var isClean: Bool { errors.isEmpty }
}

public struct SanityArtifact: Codable, Sendable, Equatable {
    public let schema: String
    public let project: String
    public let generated: String
    public let inputFingerprint: String
    public let findings: [Finding]

    private enum CodingKeys: String, CodingKey {
        case schema
        case project
        case generated
        case inputFingerprint = "input_fingerprint"
        case findings
    }

    public init(
        report: SanityReport,
        inputFingerprint: String,
        generated: String = currentTimestamp()
    ) {
        schema = "sanity/v1"
        project = report.project
        self.generated = generated
        self.inputFingerprint = inputFingerprint
        findings = report.findings
    }

    public var errors: [Finding] { findings.filter { $0.level == .error } }
}

public enum SanityArtifactStore {
    public static func save(report: SanityReport, dataRoot: URL) throws -> SanityArtifact {
        let artifact = SanityArtifact(
            report: report,
            inputFingerprint: inputFingerprint(dataRoot: dataRoot)
        )
        try JSONArtifactStore(dataRoot: dataRoot).save(
            artifact,
            to: PipelineLayout.sanityReportFile
        )
        return artifact
    }

    public static func load(dataRoot: URL) throws -> SanityArtifact {
        try JSONArtifactStore(dataRoot: dataRoot).load(
            SanityArtifact.self,
            at: PipelineLayout.sanityReportFile
        )
    }

    public static func inputFingerprint(dataRoot: URL) -> String {
        let fixedFiles = [
            PipelineLayout.briefFile,
            PipelineLayout.bibleFile,
            PipelineLayout.treatmentCurrentFile,
            PipelineLayout.storyboardCurrentFile,
            "production_design/production_design.yaml",
        ]
        var urls = fixedFiles.map { PipelineLayout.url($0, in: dataRoot) }
        if let version = latestShotlistVersion(dataRoot: dataRoot) {
            urls.append(PipelineLayout.url(PipelineLayout.shotlistVersionFile(version), in: dataRoot))
        }
        for directory in ["analysis"] {
            let root = dataRoot.appendingPathComponent(directory, isDirectory: true)
            let entries = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
            urls += entries
                .filter { relative in
                    let lower = relative.lowercased()
                    return lower.hasSuffix(".json")
                }
                .map { root.appendingPathComponent($0) }
        }

        let rootPrefix = dataRoot.standardizedFileURL.path + "/"
        let inputs = urls
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.standardizedFileURL)
            .reduce(into: [String: URL]()) { result, url in
                result[url.path] = url
            }
            .values
            .sorted { $0.path < $1.path }

        var hash: UInt64 = 14_695_981_039_346_656_037
        func absorb(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        for url in inputs {
            let relative = url.path.replacingOccurrences(of: rootPrefix, with: "")
            absorb(relative.utf8)
            absorb([UInt8(0)])
            if let data = try? Data(contentsOf: url) {
                absorb(data)
            }
            absorb([UInt8(0xff)])
        }
        return String(format: "%016llx", hash)
    }
}
