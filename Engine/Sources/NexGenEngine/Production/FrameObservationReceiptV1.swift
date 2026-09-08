import Foundation

public struct FrameObservationReceiptV1: Codable, Sendable, Equatable {
    public let id: String
    public let sourceSHA256: String
    public let transmittedImageSHA256: String
    public let mediaID: String
    public let recordedAt: String
}

public enum FrameObservationStoreV1 {
    public static let auditKey = "style.observation"

    public static func record(sourceSHA256: String, transmittedImage: Data, mediaID: String,
                              dataRoot: URL) throws -> FrameObservationReceiptV1 {
        _ = try ProjectLocalFile.resolve(PipelineLayout.projectFile, dataRoot: dataRoot)
        let receipt = FrameObservationReceiptV1(id: UUID().uuidString, sourceSHA256: sourceSHA256,
            transmittedImageSHA256: FileDigest.sha256(of: transmittedImage), mediaID: mediaID,
            recordedAt: ISO8601DateFormatter().string(from: Date()))
        let directory = dataRoot.appendingPathComponent("frames/observations")
        guard directory.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath().appendingPathComponent("frames/observations") else {
            throw GateBlocked("Frame observations cannot be stored through a symbolic link.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let imageURL = directory.appendingPathComponent(receipt.id + ".image")
        try transmittedImage.write(to: imageURL, options: .withoutOverwriting)
        do {
            try encoder.encode(receipt).write(to: directory.appendingPathComponent(receipt.id + ".json"), options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }
        return receipt
    }

    public static func require(_ id: String, sourceSHA256: String, dataRoot: URL) throws -> FrameObservationReceiptV1 {
        guard UUID(uuidString: id) != nil else { throw GateBlocked("Invalid frame observation receipt.") }
        let url = try ProjectLocalFile.resolve("frames/observations/" + id + ".json", dataRoot: dataRoot)
        let receipt = try JSONDecoder().decode(FrameObservationReceiptV1.self, from: Data(contentsOf: url))
        guard receipt.id == id, receipt.sourceSHA256 == sourceSHA256,
              receipt.transmittedImageSHA256.count == 64 else {
            throw GateBlocked("Inspect the current frame before recording its visual findings.")
        }
        _ = try ProjectLocalFile.requireHash(receipt.transmittedImageSHA256,
            at: "frames/observations/" + id + ".image", dataRoot: dataRoot)
        return receipt
    }

    public static func requireStyleAudit(_ audit: FrameAudit, style: ResolvedProductionStyleV1, dataRoot: URL) throws {
        let frameCriteria = style.criteria.filter { $0.source.scope == .frame && $0.source.evidenceKind == .image }
        let allowed = Set(frameCriteria.map(\.auditKey) + [auditKey])
        guard audit.overall == .clean,
              audit.checks.keys.filter({ $0.hasPrefix("style.") }).allSatisfy(allowed.contains) else {
            throw GateBlocked("The frame's findings must be resolved; a still cannot verify temporal or audio criteria.")
        }
        guard let observation = audit.checks[auditKey] else {
            throw GateBlocked("The frame's style review has no image observation receipt.")
        }
        let receipt = try require(observation.observed, sourceSHA256: audit.renderSha256, dataRoot: dataRoot)
        guard observation.expected == receipt.sourceSHA256,
              observation.note == receipt.transmittedImageSHA256 else {
            throw GateBlocked("The frame observation no longer matches its review.")
        }
        for criterion in frameCriteria {
            guard let check = audit.checks[criterion.auditKey], check.expected == criterion.expected else {
                throw GateBlocked("The frame is missing its current style criterion: " + criterion.source.sourceClause)
            }
            guard check.status == .clean, !check.observed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GateBlocked("Resolve the frame's style finding before approval: " + criterion.source.sourceClause)
            }
        }
    }

    public static func requireProjectStyleFrames(dataRoot: URL) throws {
        guard let style = try ProductionStyleStoreV1.load(dataRoot: dataRoot) else { return }
        guard let shotlist = try loadShotlist(dataRoot: dataRoot) else { throw GateBlocked("The shot list is missing.") }
        let manifest = try loadFramesManifest(dataRoot: dataRoot)
        let required = shotlist.shots.filter { $0.sourceMode == .generated && $0.keyframeStrategy != .none }
        guard manifest.schema == framesSchemaVersion, manifest.project == shotlist.project,
              manifest.shots.count == required.count,
              Set(manifest.shots.map(\.shotId)) == Set(required.map(\.id)) else {
            throw GateBlocked("The reviewed frames do not match the current shot list.")
        }
        for shot in required {
            let roles = shot.keyframeStrategy == .startEnd ? ["start", "end"] : ["start"]
            guard let frames = manifest.shot(shot.id)?.frames,
                  frames.count == roles.count, Set(frames.map(\.role)) == Set(roles) else {
                throw GateBlocked("Required frame roles are missing for " + shot.id)
            }
            for frame in frames {
                guard let audit = try loadFrameAudit(dataRoot: dataRoot, shotId: shot.id, role: frame.role),
                      audit.shotId == shot.id, audit.role == frame.role else {
                    throw GateBlocked("A current style audit is missing for " + shot.id)
                }
                let image = try ProjectLocalFile.resolve(frame.path, dataRoot: dataRoot)
                guard try ProjectLocalFile.resolve(audit.renderPath, dataRoot: dataRoot) == image,
                      (try FileDigest.sha256(of: image)) == audit.renderSha256 else {
                    throw GateBlocked("The reviewed frame changed for " + shot.id)
                }
                try requireStyleAudit(audit, style: style, dataRoot: dataRoot)
            }
        }
    }
}
