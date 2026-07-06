import Foundation

/// Port of `sanity/models.py::Level`.
public enum Level: String, Codable, Sendable, Equatable {
    case info
    case warn
    case error
}

/// One sanity-check result. Port of `sanity/models.py::Finding`.
public struct Finding: Sendable, Equatable {
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
}

/// The aggregate result of an audit run. Port of `sanity/models.py::SanityReport`.
public struct SanityReport: Sendable, Equatable {
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
