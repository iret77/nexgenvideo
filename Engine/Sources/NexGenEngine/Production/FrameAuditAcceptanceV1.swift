import Foundation

public struct FrameAuditAcceptanceV1: Codable, Sendable, Equatable {
    public let schema: String
    public let auditSHA256: String
    public let imageSHA256: String
    public let styleSHA256: String
    public let acceptedChecks: [String]
    public let reason: String
    public let acceptedAt: String
}

public enum FrameAuditAcceptanceStoreV1 {
    public static func unresolvedChecks(_ audit: FrameAudit) -> [String] {
        audit.checks.filter { $0.value.status == .minor || $0.value.status == .blocking }.keys.sorted()
    }

    public static func snapshot(audit: FrameAudit, dataRoot: URL) throws -> String {
        let image = try ProjectLocalFile.resolve(audit.renderPath, dataRoot: dataRoot)
        guard try FileDigest.sha256(of: image) == audit.renderSha256 else { throw GateBlocked("The reviewed image changed. Review its current audit again.") }
        _ = try ProductionStyleStoreV1.load(dataRoot: dataRoot)
        let styleURL = dataRoot.appendingPathComponent(ResolvedProductionStyleV1.relativePath)
        let style = FileManager.default.fileExists(atPath: styleURL.path) ? try FileDigest.sha256(of: styleURL) : "none"
        let path = frameAuditPath(dataRoot: dataRoot, shotId: audit.shotId, role: audit.role)
        let safePath = try ProjectLocalFile.resolve("frames/" + path.lastPathComponent, dataRoot: dataRoot)
        let current = try YAMLCoding.decode(FrameAudit.self, from: safePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(current) == encoder.encode(audit) else { throw GateBlocked("The frame findings changed. Review them again.") }
        return [try FileDigest.sha256(of: safePath), audit.renderSha256, style].joined(separator: ":")
    }

    public static func accept(audit: FrameAudit, expectedSnapshot: String, reason: String, dataRoot: URL) throws {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, !unresolvedChecks(audit).isEmpty else { throw GateBlocked("Accepting frame deviations requires visible findings and a reason.") }
        let current = try snapshot(audit: audit, dataRoot: dataRoot)
        guard current == expectedSnapshot else { throw GateBlocked("The frame review changed while it was open. Review it again.") }
        let fields = current.split(separator: ":").map(String.init)
        let acceptance = FrameAuditAcceptanceV1(schema: "frame-audit-acceptance/v1", auditSHA256: fields[0],
            imageSHA256: fields[1], styleSHA256: fields[2], acceptedChecks: unresolvedChecks(audit),
            reason: reason, acceptedAt: currentTimestamp())
        let url = try location(audit: audit, dataRoot: dataRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(acceptance).write(to: url, options: .atomic)
    }

    public static func requireResolved(audit: FrameAudit, dataRoot: URL) throws {
        let checks = unresolvedChecks(audit)
        guard !checks.isEmpty || audit.overall != .clean else { return }
        let url = try location(audit: audit, dataRoot: dataRoot)
        guard let data = try? Data(contentsOf: url),
              let acceptance = try? JSONDecoder().decode(FrameAuditAcceptanceV1.self, from: data),
              acceptance.schema == "frame-audit-acceptance/v1", acceptance.acceptedChecks == checks,
              !acceptance.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              try [acceptance.auditSHA256, acceptance.imageSHA256, acceptance.styleSHA256].joined(separator: ":") == snapshot(audit: audit, dataRoot: dataRoot) else {
            throw GateBlocked("Review and resolve the frame findings (" + checks.joined(separator: ", ") + "), or explicitly accept these exact deviations in Review before approving Frames.")
        }
    }

    public static func location(audit: FrameAudit, dataRoot: URL) throws -> URL {
        guard !audit.shotId.isEmpty, audit.shotId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              ["start", "end"].contains(audit.role) else { throw GateBlocked("Invalid frame review identity.") }
        let relative = "frames/" + audit.shotId + "-" + audit.role + ".acceptance.json"
        let url = dataRoot.appendingPathComponent(relative)
        guard url.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath().appendingPathComponent(relative) else {
            throw GateBlocked("Frame acceptance cannot be stored through a symbolic link.")
        }
        return url
    }
}
