import Darwin
import Foundation
import NexGenEngine

enum PipelineRenderRecordError: Error, LocalizedError, Sendable, Equatable {
    case invalidArtifact(String)
    case publicationFailed(String)
    case publicationRollbackFailed(String)
    case transactionInProgress(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .invalidArtifact(let detail):
            return detail
        case .publicationFailed(let detail):
            return "Render-record publication failed: \(detail)"
        case .publicationRollbackFailed(let detail):
            return "Render-record rollback failed: \(detail)"
        case .transactionInProgress(let phase):
            return "The \(phase) render record has an unfinished transaction."
        case .unsafePath(let path):
            return "Unsafe render-record path: \(path)"
        }
    }
}

enum PipelineRenderRecordWriter {
    struct PreparedLastFrame: Sendable {
        let proof: RenderLastFrameProofV1
        let data: Data
    }

    struct MutationSnapshot: Sendable {
        let publication: RenderRecordPublicationV1?
        let manifest: RenderManifest
        let proof: RenderProofManifest?
        let routingProof: PipelineRenderRoutingProofManifestV1?
        let framesManifest: FramesManifest?
    }

    enum FailurePoint: String, Sendable, Equatable {
        case transactionStarted
        case lastFrame
        case framesManifest
        case renderManifest
        case renderProof
        case renderRoutingProof
        case shotProvenanceProof
        case shotProvenancePublication
        case publication
    }

    struct ShotProvenance: Sendable, Equatable {
        let artifact: RenderPublishedArtifactV1
        let proof: RenderShotProvenanceProofV1
    }

    private struct EncodedShotProvenance {
        let artifact: RenderPublishedArtifactV1
        let proof: RenderShotProvenanceProofV1
        let data: Data
    }

    private struct Snapshot {
        let bytesByPath: [String: Data?]
        let lastFramePath: String?
        let lastFrameURL: URL?
        let lastFrameData: Data?
    }

    private struct RecoveryFile: Codable {
        let path: String
        let data: Data?
    }

    private struct RecoveryJournal: Codable {
        static let schemaVersion = "render-record-recovery/v1"

        let schema: String
        let phase: String
        let files: [RecoveryFile]
        let lastFramePath: String?
        let lastFrameData: Data?

        init(phase: String, snapshot: Snapshot) {
            schema = Self.schemaVersion
            self.phase = phase
            files = snapshot.bytesByPath.keys.sorted().map {
                RecoveryFile(
                    path: $0,
                    data: snapshot.bytesByPath[$0] ?? nil
                )
            }
            lastFramePath = snapshot.lastFramePath
            lastFrameData = snapshot.lastFrameData
        }
    }

    static func publish(
        manifest: RenderManifest,
        proof: RenderProofManifest?,
        routingProof: PipelineRenderRoutingProofManifestV1?,
        framesManifest: FramesManifest?,
        replacingShotID: String?,
        preparedLastFrame: PreparedLastFrame?,
        reconciledLastFrames: [String: RenderLastFrameProofV1]? = nil,
        expectedPublicationTransactionID: String?,
        dataRoot: URL,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil,
        failureProbe: ((FailurePoint) throws -> Void)? = nil
    ) throws -> RenderRecordPublicationV1 {
        try validatePhase(manifest.phase)
        try requireSafeLocations(
            phase: manifest.phase,
            lastFramePath: preparedLastFrame?.proof.path,
            dataRoot: dataRoot
        )
        try requirePackMutation(
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        let transactionID = UUID().uuidString.lowercased()
        let lockPath = transactionPath(phase: manifest.phase)
        let lockURL = PipelineLayout.url(lockPath, in: dataRoot)
        if FileManager.default.fileExists(atPath: lockURL.path) {
            try recoverInterruptedTransaction(
                dataRoot: dataRoot,
                phase: manifest.phase,
                lockURL: lockURL
            )
        }
        let lockDescriptor = try acquireExclusiveLock(
            transactionID: transactionID,
            lockURL: lockURL,
            phase: manifest.phase
        )
        var preserveRecoveryJournal = false
        defer {
            if !preserveRecoveryJournal,
               FileManager.default.fileExists(atPath: lockURL.path) {
                try? FileManager.default.removeItem(at: lockURL)
            }
            _ = flock(lockDescriptor, LOCK_UN)
            _ = Darwin.close(lockDescriptor)
        }
        let previousPublication = try loadPublicationIgnoringLock(
            dataRoot: dataRoot,
            phase: manifest.phase
        )
        guard previousPublication?.transactionID
                == expectedPublicationTransactionID else {
            throw PipelineRenderRecordError.publicationFailed(
                "The render record changed after this update was prepared. Reload and retry."
            )
        }
        let lastFrames: [String: RenderLastFrameProofV1]
        if let reconciledLastFrames {
            guard preparedLastFrame == nil else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "A reconciliation cannot also publish a newly extracted last frame."
                )
            }
            lastFrames = reconciledLastFrames
        } else {
            guard let replacingShotID else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "A render update must identify its replaced shot."
                )
            }
            var updated = previousPublication?.lastFrames
                ?? (try rejectLegacyLastFrames(
                    manifest: manifest,
                    excludingShotID: replacingShotID
                ))
            updated.removeValue(forKey: replacingShotID)
            if let preparedLastFrame {
                updated[replacingShotID] = preparedLastFrame.proof
            }
            lastFrames = updated
        }

        try validateArtifacts(
            manifest: manifest,
            proof: proof,
            routingProof: routingProof,
            framesManifest: framesManifest,
            lastFrames: lastFrames,
            preparedLastFrame: preparedLastFrame,
            dataRoot: dataRoot
        )

        let renderManifestData = try encode(manifest, prettyPrinted: true)
        let renderProofData = try proof.map { try encode($0, prettyPrinted: true) }
        let routingProofData = try routingProof.map { try encode($0, prettyPrinted: true) }
        let framesManifestData = try framesManifest.map { try encode($0, prettyPrinted: true) }
        let shotProvenance = try makeShotProvenance(
            manifest: manifest,
            proof: proof,
            routingProof: routingProof,
            framesManifest: framesManifest,
            lastFrames: lastFrames,
            dataRoot: dataRoot
        )
        let committedAt = currentTimestamp()
        let publication = RenderRecordPublicationV1(
            transactionID: transactionID,
            project: manifest.project,
            phase: manifest.phase,
            renderManifest: artifact(
                path: PipelineLayout.renderManifestFile(phase: manifest.phase),
                data: renderManifestData
            ),
            renderProof: renderProofData.map {
                artifact(
                    path: PipelineLayout.renderProofFile(phase: manifest.phase),
                    data: $0
                )
            },
            renderRoutingProof: routingProofData.map {
                artifact(
                    path: PipelineLayout.renderRoutingProofFile(phase: manifest.phase),
                    data: $0
                )
            },
            framesManifest: framesManifestData.map {
                artifact(path: PipelineLayout.framesManifestFile, data: $0)
            },
            lastFrames: lastFrames,
            committedAt: committedAt
        )
        let publicationData = try encode(publication, prettyPrinted: true)
        let shotProvenancePublication = RenderShotProvenancePublicationV1(
            transactionID: transactionID,
            project: manifest.project,
            phase: manifest.phase,
            proofs: shotProvenance.mapValues(\.artifact)
        )
        try RenderShotProvenanceValidatorV1.validate(
            shotProvenancePublication
        )
        let shotProvenancePublicationData = try encode(
            shotProvenancePublication,
            prettyPrinted: true
        )
        var relativeData: [(String, Data, FailurePoint)] = []
        if let framesManifestData {
            relativeData.append((
                PipelineLayout.framesManifestFile,
                framesManifestData,
                .framesManifest
            ))
        }
        relativeData.append((
            PipelineLayout.renderManifestFile(phase: manifest.phase),
            renderManifestData,
            .renderManifest
        ))
        if let renderProofData {
            relativeData.append((
                PipelineLayout.renderProofFile(phase: manifest.phase),
                renderProofData,
                .renderProof
            ))
        }
        if let routingProofData {
            relativeData.append((
                PipelineLayout.renderRoutingProofFile(phase: manifest.phase),
                routingProofData,
                .renderRoutingProof
            ))
        }
        for item in shotProvenance.values.sorted(by: {
            $0.artifact.path < $1.artifact.path
        }) {
            try requireSafeDataRootPath(item.artifact.path, dataRoot: dataRoot)
            let url = PipelineLayout.url(item.artifact.path, in: dataRoot)
            if FileManager.default.fileExists(atPath: url.path) {
                guard try Data(contentsOf: url) == item.data else {
                    throw PipelineRenderRecordError.invalidArtifact(
                        "An immutable shot-provenance path is occupied by different bytes."
                    )
                }
            } else {
                relativeData.append((
                    item.artifact.path,
                    item.data,
                    .shotProvenanceProof
                ))
            }
        }
        let shotProvenancePublicationPath = RenderShotProvenancePublicationV1
            .artifactPath(phase: manifest.phase)
        relativeData.append((
            shotProvenancePublicationPath,
            shotProvenancePublicationData,
            .shotProvenancePublication
        ))
        let publicationPath = RenderRecordPublicationV1.artifactPath(
            phase: manifest.phase
        )
        let staging = PipelineLayout.url(PipelineLayout.rendersDir, in: dataRoot)
            .appendingPathComponent(
                ".record-\(manifest.phase)-\(transactionID)",
                isDirectory: true
            )
        let lastFrameURL = try preparedLastFrame.map {
            try safeProjectURL($0.proof.path, dataRoot: dataRoot)
        }
        let snapshot = try snapshot(
            paths: Set(relativeData.map(\.0) + [publicationPath]),
            lastFramePath: preparedLastFrame?.proof.path,
            lastFrameURL: lastFrameURL,
            dataRoot: dataRoot
        )
        let fileManager = FileManager.default
        let stagedArtifacts = Dictionary(uniqueKeysWithValues: relativeData.enumerated().map { item in
            (
                item.element.0,
                staging.appendingPathComponent("artifact-\(item.offset).json")
            )
        })
        let stagedLastFrame = staging.appendingPathComponent("last-frame.png")
        let stagedPublication = staging.appendingPathComponent("publication.json")
        let stagedRecovery = staging.appendingPathComponent("recovery.json")
        var canonicalWritesStarted = false

        do {
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false
            )
            for item in relativeData {
                try item.1.write(
                    to: stagedArtifacts[item.0]!,
                    options: .atomic
                )
            }
            if let preparedLastFrame {
                try preparedLastFrame.data.write(
                    to: stagedLastFrame,
                    options: .atomic
                )
            }
            try publicationData.write(
                to: stagedPublication,
                options: .atomic
            )
            try encode(
                RecoveryJournal(phase: manifest.phase, snapshot: snapshot),
                prettyPrinted: true
            ).write(to: stagedRecovery, options: .atomic)

            try failureProbe?(.transactionStarted)
            try requirePackMutation(
                dataRoot: dataRoot,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
            canonicalWritesStarted = true
            if let preparedLastFrame, let lastFrameURL {
                try Data(contentsOf: stagedLastFrame).write(
                    to: lastFrameURL,
                    options: .atomic
                )
                try failureProbe?(.lastFrame)
            }
            for item in relativeData {
                try write(
                    Data(contentsOf: stagedArtifacts[item.0]!),
                    to: item.0,
                    dataRoot: dataRoot
                )
                try failureProbe?(item.2)
            }
            try verifyArtifactBytes(
                relativeData,
                preparedLastFrame: preparedLastFrame,
                lastFrameURL: lastFrameURL,
                dataRoot: dataRoot
            )
            try write(
                Data(contentsOf: stagedPublication),
                to: publicationPath,
                dataRoot: dataRoot
            )
            try failureProbe?(.publication)
            try verifyPublication(
                publication,
                expectedData: publicationData,
                dataRoot: dataRoot
            )
            try? fileManager.removeItem(at: staging)
            return publication
        } catch {
            if !canonicalWritesStarted {
                try? fileManager.removeItem(at: staging)
                if let error = error as? PipelineRenderRecordError {
                    throw error
                }
                throw PipelineRenderRecordError.publicationFailed(
                    error.localizedDescription
                )
            }
            do {
                try restore(
                    snapshot,
                    publicationPath: publicationPath,
                    dataRoot: dataRoot
                )
                try? fileManager.removeItem(at: staging)
            } catch {
                preserveRecoveryJournal = true
                throw PipelineRenderRecordError.publicationRollbackFailed(
                    error.localizedDescription
                )
            }
            if let error = error as? PipelineRenderRecordError {
                throw error
            }
            throw PipelineRenderRecordError.publicationFailed(
                error.localizedDescription
            )
        }
    }

    static func loadMutationSnapshot(
        dataRoot: URL,
        phase: String,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) throws -> MutationSnapshot {
        try validatePhase(phase)
        try requireSafeLocations(
            phase: phase,
            lastFramePath: nil,
            dataRoot: dataRoot
        )
        try requirePackMutation(
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        let lockURL = PipelineLayout.url(
            transactionPath(phase: phase),
            in: dataRoot
        )
        if FileManager.default.fileExists(atPath: lockURL.path) {
            try recoverInterruptedTransaction(
                dataRoot: dataRoot,
                phase: phase,
                lockURL: lockURL
            )
        }
        let descriptor = try acquireExclusiveLock(
            transactionID: UUID().uuidString.lowercased(),
            lockURL: lockURL,
            phase: phase
        )
        defer {
            try? FileManager.default.removeItem(at: lockURL)
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        let publication = try loadPublicationIgnoringLock(
            dataRoot: dataRoot,
            phase: phase
        )
        let manifest = try loadRenderManifest(
            dataRoot: dataRoot,
            phase: phase
        )
        if phase == "frames" {
            let framesURL = PipelineLayout.url(
                PipelineLayout.framesManifestFile,
                in: dataRoot
            )
            let frames = FileManager.default.fileExists(atPath: framesURL.path)
                ? try loadFramesManifest(dataRoot: dataRoot)
                : FramesManifest(
                    project: manifest.project,
                    generated: currentTimestamp()
                )
            return MutationSnapshot(
                publication: publication,
                manifest: manifest,
                proof: nil,
                routingProof: nil,
                framesManifest: frames
            )
        }
        return MutationSnapshot(
            publication: publication,
            manifest: manifest,
            proof: try loadRenderProofManifest(
                dataRoot: dataRoot,
                phase: phase
            ),
            routingProof: try PipelineRenderRoutingProofStore.load(
                dataRoot: dataRoot,
                phase: phase
            ),
            framesManifest: nil
        )
    }

    @discardableResult
    static func reconcilePhasePreparation(
        shotlist: Shotlist,
        phase: String,
        dataRoot: URL,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) throws -> RenderRecordPublicationV1 {
        guard phase == "frames" || phase == "final" else {
            throw PipelineRenderRecordError.invalidArtifact(
                "Only Frames and final Render have host preparation records."
            )
        }
        let snapshot = try loadMutationSnapshot(
            dataRoot: dataRoot,
            phase: phase,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        guard snapshot.manifest.project == shotlist.project,
              snapshot.manifest.phase == phase else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The \(phase) render manifest does not match the approved Shot List."
            )
        }
        if phase == "frames" {
            guard let currentFrames = snapshot.framesManifest else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "The Frames manifest is unavailable."
                )
            }
            let eligible = Set(shotlist.shots.compactMap { shot in
                shot.sourceMode == .generated && shot.keyframeStrategy != .none
                    ? shot.id
                    : nil
            })
            let frames = try currentFrames.reconciled(
                with: shotlist,
                generated: currentFrames.generated
            )
            var manifest = snapshot.manifest
            manifest.entries = manifest.entries.filter {
                eligible.contains($0.key)
            }
            for shotFrames in frames.shots where !shotFrames.frames.isEmpty {
                guard let entry = manifest.entries[shotFrames.shotId],
                      entry.status == .rendered,
                      let output = entry.output,
                      shotFrames.frames.contains(where: { $0.path == output }) else {
                    throw PipelineRenderRecordError.invalidArtifact(
                        "Frames for \(shotFrames.shotId) have no matching render ledger entry."
                    )
                }
            }
            if let publication = snapshot.publication,
               manifest == snapshot.manifest,
               frames == currentFrames,
               publication.lastFrames.isEmpty,
               try hasMatchingShotProvenancePublication(
                   publication,
                   dataRoot: dataRoot
               ) {
                return publication
            }
            return try publish(
                manifest: manifest,
                proof: nil,
                routingProof: nil,
                framesManifest: frames,
                replacingShotID: nil,
                preparedLastFrame: nil,
                reconciledLastFrames: [:],
                expectedPublicationTransactionID: snapshot.publication?.transactionID,
                dataRoot: dataRoot,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
        }

        guard let currentProof = snapshot.proof,
              let currentRoutingProof = snapshot.routingProof,
              currentProof.project == shotlist.project,
              currentProof.phase == phase,
              currentRoutingProof.project == shotlist.project,
              currentRoutingProof.phase == phase else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The final render provenance does not match the approved Shot List."
            )
        }
        var proof = currentProof
        var routingProof = currentRoutingProof
        let required = Set(
            shotlist.shots
                .filter { $0.sourceMode != .imported }
                .map(\.id)
        )
        var manifest = snapshot.manifest
        manifest.entries = manifest.entries.filter { required.contains($0.key) }
        let rendered = Set(manifest.entries.compactMap { item in
            item.value.status == .rendered ? item.key : nil
        })
        proof.entries = proof.entries.filter { rendered.contains($0.key) }
        routingProof.entries = routingProof.entries.filter {
            rendered.contains($0.key)
        }
        let lastFrames = snapshot.publication?.lastFrames.filter {
            rendered.contains($0.key)
        } ?? [:]
        let expectedLastFrames = Set(manifest.entries.compactMap { item in
            item.value.lastFramePath == nil ? nil : item.key
        })
        let requiredLastFrames = Set(rendered.filter { shotID in
            ChainContinuity.needsLastFrame(shotlist, shotId: shotID)
        })
        guard expectedLastFrames == requiredLastFrames,
              expectedLastFrames == Set(lastFrames.keys) else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The reconciled final render has an unproved predecessor frame. Rerender it first."
            )
        }
        if let publication = snapshot.publication,
           manifest == snapshot.manifest,
           proof == currentProof,
           routingProof == currentRoutingProof,
           lastFrames == publication.lastFrames,
           try hasMatchingShotProvenancePublication(
               publication,
               dataRoot: dataRoot
           ) {
            return publication
        }
        return try publish(
            manifest: manifest,
            proof: proof,
            routingProof: routingProof,
            framesManifest: nil,
            replacingShotID: nil,
            preparedLastFrame: nil,
            reconciledLastFrames: lastFrames,
            expectedPublicationTransactionID: snapshot.publication?.transactionID,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
    }

    private static func requirePackMutation(
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?
    ) throws {
        _ = try ProjectPackGate.requireMutation(
            projectURL: FrameInventory.projectHome(of: dataRoot),
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
    }

    @discardableResult
    static func requireCurrentPublicationIfPresent(
        dataRoot: URL,
        phase: String
    ) throws -> RenderRecordPublicationV1? {
        try validatePhase(phase)
        try requireSafeLocations(
            phase: phase,
            lastFramePath: nil,
            dataRoot: dataRoot
        )
        return try loadCurrentPublicationIfPresent(
            dataRoot: dataRoot,
            phase: phase
        )
    }

    @MainActor
    static func requireCurrentShotProvenance(
        dataRoot: URL,
        phase: String,
        shotID: String
    ) throws -> ShotProvenance {
        try validatePhase(phase)
        try requireSafeLocations(
            phase: phase,
            lastFramePath: nil,
            dataRoot: dataRoot
        )
        guard let mainPublication = try loadCurrentPublicationIfPresent(
            dataRoot: dataRoot,
            phase: phase
        ), let (publication, _) = try loadShotProvenancePublication(
            dataRoot: dataRoot,
            phase: phase
        ), publication.schema == RenderShotProvenancePublicationV1.schemaVersion,
           publication.transactionID == mainPublication.transactionID,
           publication.project == mainPublication.project,
           publication.phase == phase,
           let artifact = publication.proofs[shotID] else {
            throw PipelineRenderRecordError.invalidArtifact(
                "Shot \(shotID) has no immutable \(phase) render provenance."
            )
        }
        let proofURL = try ProjectLocalFile.requireHash(
            artifact.sha256,
            at: artifact.path,
            dataRoot: dataRoot
        )
        let proof = try JSONDecoder().decode(
            RenderShotProvenanceProofV1.self,
            from: Data(contentsOf: proofURL)
        )
        try RenderShotProvenanceValidatorV1.validate(
            proof,
            artifactPath: artifact.path,
            artifactSHA256: artifact.sha256
        )
        guard proof.project == mainPublication.project,
              proof.phase == phase,
              proof.shotID == shotID else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The immutable render provenance for \(shotID) has the wrong identity."
            )
        }
        for output in proof.outputs {
            _ = try ProjectLocalFile.requireHash(
                output.sha256,
                at: output.path,
                dataRoot: dataRoot
            )
        }
        for dependency in proof.dependencies {
            _ = try ProjectLocalFile.requireHash(
                dependency.sha256,
                at: dependency.path,
                dataRoot: dataRoot
            )
        }
        if phase == "frames" {
            guard let frames = proof.frames else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "The immutable Frames provenance for \(shotID) is incomplete."
                )
            }
            for frame in frames.frames {
                _ = try ProjectLocalFile.resolve(frame.path, dataRoot: dataRoot)
            }
        } else {
            guard let outputProof = proof.renderProofEntry,
                  let routingData = proof.routingProofEntry,
                  let routingEntry = try? JSONDecoder().decode(
                      PipelineRenderRoutingProofEntryV1.self,
                      from: routingData
                  ),
                  try encode(routingEntry, prettyPrinted: false) == routingData,
                  routingEntry.shotID == shotID,
                  routingEntry.output == outputProof.output,
                  routingEntry.outputSHA256 == outputProof.outputSha256 else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "The immutable routing provenance for \(shotID) is incomplete."
                )
            }
            _ = try ProjectLocalFile.requireHash(
                outputProof.outputSha256,
                at: outputProof.output,
                dataRoot: dataRoot
            )
            try PipelineProductionRouting.validateHistoricalProof(
                routingEntry.generation,
                dataRoot: dataRoot
            )
            if let lastFrame = proof.lastFrame {
                _ = try ProjectLocalFile.requireHash(
                    lastFrame.sha256,
                    at: lastFrame.path,
                    dataRoot: dataRoot
                )
            }
        }
        return ShotProvenance(artifact: artifact, proof: proof)
    }

    private static func loadCurrentPublicationIfPresent(
        dataRoot: URL,
        phase: String
    ) throws -> RenderRecordPublicationV1? {
        let lockURL = PipelineLayout.url(transactionPath(phase: phase), in: dataRoot)
        if FileManager.default.fileExists(atPath: lockURL.path) {
            try recoverInterruptedTransaction(
                dataRoot: dataRoot,
                phase: phase,
                lockURL: lockURL
            )
        }
        return try loadPublicationIgnoringLock(
            dataRoot: dataRoot,
            phase: phase
        )
    }

    private static func loadPublicationIgnoringLock(
        dataRoot: URL,
        phase: String
    ) throws -> RenderRecordPublicationV1? {
        let path = RenderRecordPublicationV1.artifactPath(phase: phase)
        let url = PipelineLayout.url(path, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let before = try Data(contentsOf: url)
            let publication = try JSONDecoder().decode(
                RenderRecordPublicationV1.self,
                from: before
            )
            guard publication.phase == phase else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "The \(phase) render-record publication has the wrong phase identity."
                )
            }
            try verifyPublication(
                publication,
                expectedData: before,
                dataRoot: dataRoot
            )
            guard try Data(contentsOf: url) == before else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "The \(phase) render-record publication changed while it was read."
                )
            }
            return publication
        } catch let error as PipelineRenderRecordError {
            throw error
        } catch {
            throw PipelineRenderRecordError.invalidArtifact(
                "The \(phase) render-record publication is unreadable: \(error.localizedDescription)"
            )
        }
    }

    private static func validateArtifacts(
        manifest: RenderManifest,
        proof: RenderProofManifest?,
        routingProof: PipelineRenderRoutingProofManifestV1?,
        framesManifest: FramesManifest?,
        lastFrames: [String: RenderLastFrameProofV1],
        preparedLastFrame: PreparedLastFrame?,
        dataRoot: URL
    ) throws {
        guard manifest.schema_ == renderManifestSchemaVersion,
              !manifest.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.entries.allSatisfy({ item in
                  item.key == item.value.shotId
                      && item.value.phase == manifest.phase
              }) else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The render manifest has invalid identity."
            )
        }
        if manifest.phase == "frames" {
            let renderedShotIDs = Set(manifest.entries.compactMap { item in
                item.value.status == .rendered ? item.key : nil
            })
            let frameShotIDs = Set(framesManifest?.shots.compactMap { shot in
                shot.frames.isEmpty ? nil : shot.shotId
            } ?? [])
            guard proof == nil,
                  routingProof == nil,
                  let framesManifest,
                  framesManifest.schema == framesSchemaVersion,
                  framesManifest.project == manifest.project,
                  Set(framesManifest.shots.map(\.shotId)).count
                    == framesManifest.shots.count,
                  framesManifest.shots.allSatisfy({ shot in
                      Set(shot.frames.map(\.role)).count == shot.frames.count
                  }),
                  renderedShotIDs == frameShotIDs,
                  manifest.entries.allSatisfy({ item in
                      item.value.status != .rendered
                          || (item.value.output.map { output in
                              framesManifest.shot(item.key)?.frames.contains {
                                  $0.path == output
                              } == true
                          } == true)
                  }),
                  lastFrames.isEmpty else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "Frames must publish only their render and Frames manifests."
                )
            }
        } else {
            guard framesManifest == nil,
                  let proof,
                  proof.schema == renderProofSchemaVersion,
                  proof.project == manifest.project,
                  proof.phase == manifest.phase,
                  let routingProof,
                  routingProof.schema
                    == PipelineRenderRoutingProofManifestV1.schemaVersion,
                  routingProof.project == manifest.project,
                  routingProof.phase == manifest.phase else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "Video renders must publish matching render and routing provenance."
                )
            }
            let renderedShotIDs = Set(manifest.entries.compactMap { item in
                item.value.status == .rendered ? item.key : nil
            })
            guard Set(proof.entries.keys) == renderedShotIDs,
                  Set(routingProof.entries.keys) == renderedShotIDs else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "Rendered shots, render proofs, and routing proofs must have exact coverage."
                )
            }
            for (shotID, entryProof) in proof.entries {
                guard shotID == entryProof.shotId,
                      entryProof.outputSha256.count == 64,
                      entryProof.outputSha256.allSatisfy(\.isHexDigit),
                      let entry = manifest.entries[shotID],
                      entry.status == .rendered,
                      entry.output == entryProof.output else {
                    throw PipelineRenderRecordError.invalidArtifact(
                        "Render provenance for \(shotID) does not match the manifest."
                    )
                }
                _ = try ProjectLocalFile.requireHash(
                    entryProof.outputSha256,
                    at: entryProof.output,
                    dataRoot: dataRoot
                )
                let inputs = [
                    entryProof.sourceVideo,
                    entryProof.startFrame,
                    entryProof.endFrame,
                ].compactMap { $0 }
                    + entryProof.referenceImages
                    + entryProof.referenceVideos
                    + entryProof.referenceAudio
                for input in inputs {
                    _ = try ProjectLocalFile.requireHash(
                        input.sha256,
                        at: input.path,
                        dataRoot: dataRoot
                    )
                }
            }
            for (shotID, routeProof) in routingProof.entries {
                guard shotID == routeProof.shotID,
                      let entryProof = proof.entries[shotID],
                      routeProof.output == entryProof.output,
                      routeProof.outputSHA256 == entryProof.outputSha256,
                      routeProof.generation.modelID == entryProof.generationModel,
                      routeProof.generation.schema
                        == ProductionGenerationRoutingProofV1.schemaVersion,
                      routeProof.generation.projectID == manifest.project,
                      routeProof.generation.shotID == shotID else {
                    throw PipelineRenderRecordError.invalidArtifact(
                        "Routing provenance for \(shotID) does not match the render proof."
                    )
                }
                guard renderProofMatchesRouting(
                    entryProof,
                    generation: routeProof.generation
                ) else {
                    throw PipelineRenderRecordError.invalidArtifact(
                        "Rendered inputs for \(shotID) do not match the exact ReferencePlan."
                    )
                }
                try PipelineProductionRouting.validateHistoricalProof(
                    routeProof.generation,
                    dataRoot: dataRoot
                )
            }
        }
        let preparedByPath = preparedLastFrame.map { [$0.proof.path: $0.data] } ?? [:]
        let expectedLastFrameShots = Set(manifest.entries.compactMap { item in
            item.value.lastFramePath == nil ? nil : item.key
        })
        guard expectedLastFrameShots == Set(lastFrames.keys) else {
            throw PipelineRenderRecordError.invalidArtifact(
                "Every recorded last frame must have exact publication provenance."
            )
        }
        for (shotID, frameProof) in lastFrames {
            guard frameProof.shotID == shotID,
                  frameProof.phase == manifest.phase,
                  frameProof.sha256.count == 64,
                  frameProof.sha256.allSatisfy(\.isHexDigit),
                  frameProof.sourceOutputSHA256.count == 64,
                  frameProof.sourceOutputSHA256.allSatisfy(\.isHexDigit),
                  frameProof.extractor == RenderLastFrameProofV1.extractorID,
                  !frameProof.extractedAt.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  let entry = manifest.entries[shotID],
                  entry.status == .rendered,
                  entry.output == frameProof.sourceOutput,
                  entry.lastFramePath == frameProof.path,
                  let entryProof = proof?.entries[shotID],
                  entryProof.output == frameProof.sourceOutput,
                  entryProof.outputSha256 == frameProof.sourceOutputSHA256 else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "Last-frame provenance for \(shotID) is incomplete or mismatched."
                )
            }
            if let data = preparedByPath[frameProof.path] {
                guard FileDigest.sha256(of: data) == frameProof.sha256 else {
                    throw PipelineRenderRecordError.invalidArtifact(
                        "The extracted last-frame bytes for \(shotID) do not match their proof."
                    )
                }
            } else {
                _ = try ProjectLocalFile.requireHash(
                    frameProof.sha256,
                    at: frameProof.path,
                    dataRoot: dataRoot
                )
            }
            _ = try ProjectLocalFile.requireHash(
                frameProof.sourceOutputSHA256,
                at: frameProof.sourceOutput,
                dataRoot: dataRoot
            )
        }
    }

    private static func renderProofMatchesRouting(
        _ renderProof: RenderProofEntry,
        generation: ProductionGenerationRoutingProofV1
    ) -> Bool {
        let bindings = generation.orderedBindings
        let source = bindings.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.sourceVideo
            )
        }
        let start = bindings.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.firstFrame
            ) || ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame
            )
        }
        let end = bindings.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.lastFrame
            )
        }
        let coreSemanticJobIDs = [
            CoreReferenceSemanticJobIDV1.sourceVideo,
            CoreReferenceSemanticJobIDV1.firstFrame,
            CoreReferenceSemanticJobIDV1.predecessorLastFrame,
            CoreReferenceSemanticJobIDV1.lastFrame,
        ]
        let ordinary = bindings.filter { binding in
            !coreSemanticJobIDs.contains(where: {
                ProductionIdentifierNormalizerV1.matches(
                    binding.semanticJobID,
                    $0
                )
            })
        }
        func input(_ binding: ProductionGenerationRoutingBindingV1) -> RenderInputProof {
            RenderInputProof(path: binding.path, sha256: binding.sha256)
        }
        guard source.count <= 1,
              start.count <= 1,
              end.count <= 1,
              renderProof.sourceVideo == source.first.map(input),
              renderProof.startFrame == start.first.map(input),
              renderProof.endFrame == end.first.map(input),
              renderProof.referenceImages == ordinary.filter({
                  $0.modalityID == AssetPhysicalModalityV1.image.rawValue
              }).map(input),
              renderProof.referenceVideos == ordinary.filter({
                  $0.modalityID == AssetPhysicalModalityV1.video.rawValue
              }).map(input),
              renderProof.referenceAudio == ordinary.filter({
                  $0.modalityID == AssetPhysicalModalityV1.audio.rawValue
              }).map(input) else {
            return false
        }
        return ordinary.allSatisfy {
            [
                AssetPhysicalModalityV1.image.rawValue,
                AssetPhysicalModalityV1.video.rawValue,
                AssetPhysicalModalityV1.audio.rawValue,
            ].contains($0.modalityID)
        }
    }

    private static func makeShotProvenance(
        manifest: RenderManifest,
        proof: RenderProofManifest?,
        routingProof: PipelineRenderRoutingProofManifestV1?,
        framesManifest: FramesManifest?,
        lastFrames: [String: RenderLastFrameProofV1],
        dataRoot: URL
    ) throws -> [String: EncodedShotProvenance] {
        var result: [String: EncodedShotProvenance] = [:]
        for (shotID, entry) in manifest.entries where entry.status == .rendered {
            let routingData = try routingProof?.entries[shotID].map {
                try encode($0, prettyPrinted: false)
            }
            let shotProof = RenderShotProvenanceProofV1(
                project: manifest.project,
                phase: manifest.phase,
                shotID: shotID,
                renderEntry: entry,
                renderProofEntry: proof?.entries[shotID],
                routingProofEntry: routingData,
                frames: framesManifest?.shot(shotID),
                lastFrame: lastFrames[shotID],
                outputs: try shotProvenanceOutputs(
                    renderProof: proof?.entries[shotID],
                    frames: framesManifest?.shot(shotID),
                    lastFrame: lastFrames[shotID],
                    dataRoot: dataRoot
                ),
                dependencies: try shotProvenanceDependencies(
                    renderProof: proof?.entries[shotID],
                    routingProof: routingProof?.entries[shotID]
                )
            )
            try RenderShotProvenanceValidatorV1.validate(shotProof)
            let data = try encode(shotProof, prettyPrinted: false)
            let sha256 = FileDigest.sha256(of: data)
            let path = RenderShotProvenanceProofV1.artifactPath(
                phase: manifest.phase,
                shotID: shotID,
                sha256: sha256
            )
            result[shotID] = EncodedShotProvenance(
                artifact: RenderPublishedArtifactV1(path: path, sha256: sha256),
                proof: shotProof,
                data: data
            )
        }
        return result
    }

    private static func shotProvenanceOutputs(
        renderProof: RenderProofEntry?,
        frames: ShotFrames?,
        lastFrame: RenderLastFrameProofV1?,
        dataRoot: URL
    ) throws -> [RenderPublishedArtifactV1] {
        var sha256ByPath: [String: String] = [:]
        func add(path: String, sha256: String) throws {
            if let existing = sha256ByPath[path], existing != sha256 {
                throw PipelineRenderRecordError.invalidArtifact(
                    "A shot-provenance output has conflicting hashes for \(path)."
                )
            }
            sha256ByPath[path] = sha256
        }
        if let renderProof {
            try add(
                path: renderProof.output,
                sha256: renderProof.outputSha256
            )
        }
        if let lastFrame {
            try add(path: lastFrame.path, sha256: lastFrame.sha256)
        }
        if let frames {
            for frame in frames.frames {
                let url = try ProjectLocalFile.resolve(
                    frame.path,
                    dataRoot: dataRoot
                )
                try add(
                    path: frame.path,
                    sha256: try FileDigest.sha256(of: url)
                )
            }
        }
        return sha256ByPath.map {
            RenderPublishedArtifactV1(path: $0.key, sha256: $0.value)
        }.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.sha256 < $1.sha256
        }
    }

    private static func shotProvenanceDependencies(
        renderProof: RenderProofEntry?,
        routingProof: PipelineRenderRoutingProofEntryV1?
    ) throws -> [RenderPublishedArtifactV1] {
        var sha256ByPath: [String: String] = [:]
        func add(path: String, sha256: String) throws {
            if let existing = sha256ByPath[path], existing != sha256 {
                throw PipelineRenderRecordError.invalidArtifact(
                    "A shot-provenance dependency has conflicting hashes for \(path)."
                )
            }
            sha256ByPath[path] = sha256
        }
        if let renderProof {
            let inputs = [
                renderProof.sourceVideo,
                renderProof.startFrame,
                renderProof.endFrame,
            ].compactMap { $0 }
                + renderProof.referenceImages
                + renderProof.referenceVideos
                + renderProof.referenceAudio
            for input in inputs {
                try add(path: input.path, sha256: input.sha256)
            }
        }
        if let graph = routingProof?.generation.historicalAssetGraph {
            for asset in graph.assets {
                try add(path: asset.path, sha256: asset.sha256)
                switch (
                    asset.provenance.sourceProofPath,
                    asset.provenance.sourceProofSHA256
                ) {
                case (let path?, let sha256?):
                    try add(path: path, sha256: sha256)
                case (nil, nil):
                    break
                default:
                    throw PipelineRenderRecordError.invalidArtifact(
                        "A historical AssetGraph dependency has incomplete provenance."
                    )
                }
            }
        }
        return sha256ByPath.map {
            RenderPublishedArtifactV1(path: $0.key, sha256: $0.value)
        }.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.sha256 < $1.sha256
        }
    }

    private static func loadShotProvenancePublication(
        dataRoot: URL,
        phase: String
    ) throws -> (RenderShotProvenancePublicationV1, Data)? {
        let path = RenderShotProvenancePublicationV1.artifactPath(phase: phase)
        let url = PipelineLayout.url(path, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let before = try Data(contentsOf: url)
        let publication = try JSONDecoder().decode(
            RenderShotProvenancePublicationV1.self,
            from: before
        )
        guard try Data(contentsOf: url) == before else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The \(phase) shot-provenance publication changed while it was read."
            )
        }
        return (publication, before)
    }

    private static func hasMatchingShotProvenancePublication(
        _ mainPublication: RenderRecordPublicationV1,
        dataRoot: URL
    ) throws -> Bool {
        guard let (publication, _) = try loadShotProvenancePublication(
            dataRoot: dataRoot,
            phase: mainPublication.phase
        ) else { return false }
        try RenderShotProvenanceValidatorV1.validate(publication)
        return publication.schema == RenderShotProvenancePublicationV1.schemaVersion
            && publication.transactionID == mainPublication.transactionID
            && publication.project == mainPublication.project
            && publication.phase == mainPublication.phase
    }

    @discardableResult
    private static func verifyShotProvenancePublicationIfPresent(
        mainPublication: RenderRecordPublicationV1,
        manifest: RenderManifest,
        proof: RenderProofManifest?,
        routingProof: PipelineRenderRoutingProofManifestV1?,
        framesManifest: FramesManifest?,
        dataRoot: URL
    ) throws -> Bool {
        guard let (publication, publicationData) = try loadShotProvenancePublication(
            dataRoot: dataRoot,
            phase: mainPublication.phase
        ) else { return false }
        try RenderShotProvenanceValidatorV1.validate(publication)
        let expected = try makeShotProvenance(
            manifest: manifest,
            proof: proof,
            routingProof: routingProof,
            framesManifest: framesManifest,
            lastFrames: mainPublication.lastFrames,
            dataRoot: dataRoot
        )
        guard publication.schema == RenderShotProvenancePublicationV1.schemaVersion,
              publication.transactionID == mainPublication.transactionID,
              publication.project == mainPublication.project,
              publication.phase == mainPublication.phase,
              publication.proofs == expected.mapValues(\.artifact) else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The shot-provenance publication does not match the render transaction."
            )
        }
        for (shotID, item) in expected {
            let persisted = try ProjectLocalFile.requireHash(
                item.artifact.sha256,
                at: item.artifact.path,
                dataRoot: dataRoot
            )
            let data = try Data(contentsOf: persisted)
            guard data == item.data,
                  try JSONDecoder().decode(
                      RenderShotProvenanceProofV1.self,
                      from: data
                  ) == item.proof else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "The immutable shot-provenance proof for \(shotID) is invalid."
                )
            }
            try RenderShotProvenanceValidatorV1.validate(
                item.proof,
                artifactPath: item.artifact.path,
                artifactSHA256: item.artifact.sha256
            )
            for output in item.proof.outputs {
                _ = try ProjectLocalFile.requireHash(
                    output.sha256,
                    at: output.path,
                    dataRoot: dataRoot
                )
            }
            for dependency in item.proof.dependencies {
                _ = try ProjectLocalFile.requireHash(
                    dependency.sha256,
                    at: dependency.path,
                    dataRoot: dataRoot
                )
            }
        }
        let publicationURL = PipelineLayout.url(
            RenderShotProvenancePublicationV1.artifactPath(
                phase: mainPublication.phase
            ),
            in: dataRoot
        )
        guard try Data(contentsOf: publicationURL) == publicationData else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The shot-provenance commit marker changed while it was verified."
            )
        }
        return true
    }

    private static func rejectLegacyLastFrames(
        manifest: RenderManifest,
        excludingShotID: String
    ) throws -> [String: RenderLastFrameProofV1] {
        for (shotID, entry) in manifest.entries where shotID != excludingShotID {
            guard entry.lastFramePath == nil else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "Legacy last frame for \(shotID) has no extraction proof. "
                        + "Rerender that predecessor before recording another shot."
                )
            }
        }
        return [:]
    }

    private static func verifyPublication(
        _ publication: RenderRecordPublicationV1,
        expectedData: Data,
        dataRoot: URL
    ) throws {
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(
            ProjectMeta.self,
            at: PipelineLayout.projectFile
        )
        guard publication.schema == RenderRecordPublicationV1.schemaVersion,
              UUID(uuidString: publication.transactionID) != nil,
              ["frames", "preview", "final"].contains(publication.phase),
              !publication.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !publication.committedAt.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              publication.project == project.project,
              publication.renderManifest.path
                == PipelineLayout.renderManifestFile(phase: publication.phase),
              publication.renderProof?.path
                == (publication.phase == "frames"
                    ? nil
                    : PipelineLayout.renderProofFile(phase: publication.phase)),
              publication.renderRoutingProof?.path
                == (publication.phase == "frames"
                    ? nil
                    : PipelineLayout.renderRoutingProofFile(phase: publication.phase)),
              publication.framesManifest?.path
                == (publication.phase == "frames"
                    ? PipelineLayout.framesManifestFile
                    : nil) else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The render-record publication has invalid artifact identities."
            )
        }
        var artifacts = [publication.renderManifest]
        if let renderProof = publication.renderProof {
            artifacts.append(renderProof)
        }
        if let routingProof = publication.renderRoutingProof {
            artifacts.append(routingProof)
        }
        if let framesManifest = publication.framesManifest {
            artifacts.append(framesManifest)
        }
        var dataByPath: [String: Data] = [:]
        for artifact in artifacts {
            let data = try Data(
                contentsOf: PipelineLayout.url(artifact.path, in: dataRoot)
            )
            guard artifact.sha256 == FileDigest.sha256(of: data) else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "Published artifact \(artifact.path) does not match its commit marker."
                )
            }
            dataByPath[artifact.path] = data
        }
        for (shotID, proof) in publication.lastFrames {
            guard proof.shotID == shotID else {
                throw PipelineRenderRecordError.invalidArtifact(
                    "Published last-frame identity does not match \(shotID)."
                )
            }
            _ = try ProjectLocalFile.requireHash(
                proof.sha256,
                at: proof.path,
                dataRoot: dataRoot
            )
        }
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(
            RenderManifest.self,
            from: dataByPath[publication.renderManifest.path]!
        )
        let renderProof = try publication.renderProof.map {
            try decoder.decode(RenderProofManifest.self, from: dataByPath[$0.path]!)
        }
        let routingProof = try publication.renderRoutingProof.map {
            try decoder.decode(
                PipelineRenderRoutingProofManifestV1.self,
                from: dataByPath[$0.path]!
            )
        }
        let framesManifest = try publication.framesManifest.map {
            try decoder.decode(FramesManifest.self, from: dataByPath[$0.path]!)
        }
        guard manifest.project == publication.project,
              manifest.phase == publication.phase else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The render manifest does not match its publication identity."
            )
        }
        try validateArtifacts(
            manifest: manifest,
            proof: renderProof,
            routingProof: routingProof,
            framesManifest: framesManifest,
            lastFrames: publication.lastFrames,
            preparedLastFrame: nil,
            dataRoot: dataRoot
        )
        _ = try verifyShotProvenancePublicationIfPresent(
            mainPublication: publication,
            manifest: manifest,
            proof: renderProof,
            routingProof: routingProof,
            framesManifest: framesManifest,
            dataRoot: dataRoot
        )
        let publicationURL = PipelineLayout.url(
            RenderRecordPublicationV1.artifactPath(phase: publication.phase),
            in: dataRoot
        )
        guard try Data(contentsOf: publicationURL) == expectedData else {
            throw PipelineRenderRecordError.invalidArtifact(
                "The render-record commit marker changed while it was verified."
            )
        }
    }

    private static func verifyArtifactBytes(
        _ relativeData: [(String, Data, FailurePoint)],
        preparedLastFrame: PreparedLastFrame?,
        lastFrameURL: URL?,
        dataRoot: URL
    ) throws {
        for item in relativeData {
            guard try Data(contentsOf: PipelineLayout.url(item.0, in: dataRoot))
                    == item.1 else {
                throw PipelineRenderRecordError.publicationFailed(
                    "Persisted bytes differ for \(item.0)."
                )
            }
        }
        if let preparedLastFrame, let lastFrameURL {
            guard try Data(contentsOf: lastFrameURL) == preparedLastFrame.data else {
                throw PipelineRenderRecordError.publicationFailed(
                    "Persisted last-frame bytes differ for \(preparedLastFrame.proof.path)."
                )
            }
        }
    }

    private static func artifact(path: String, data: Data) -> RenderPublishedArtifactV1 {
        RenderPublishedArtifactV1(
            path: path,
            sha256: FileDigest.sha256(of: data)
        )
    }

    private static func snapshot(
        paths: Set<String>,
        lastFramePath: String?,
        lastFrameURL: URL?,
        dataRoot: URL
    ) throws -> Snapshot {
        var bytes: [String: Data?] = [:]
        for path in paths {
            let url = PipelineLayout.url(path, in: dataRoot)
            bytes.updateValue(
                FileManager.default.fileExists(atPath: url.path)
                    ? try Data(contentsOf: url)
                    : nil,
                forKey: path
            )
        }
        let lastFrameData = try lastFrameURL.flatMap { url -> Data? in
            FileManager.default.fileExists(atPath: url.path)
                ? try Data(contentsOf: url)
                : nil
        }
        return Snapshot(
            bytesByPath: bytes,
            lastFramePath: lastFramePath,
            lastFrameURL: lastFrameURL,
            lastFrameData: lastFrameData
        )
    }

    private static func recoverInterruptedTransaction(
        dataRoot: URL,
        phase: String,
        lockURL: URL
    ) throws {
        let fileManager = FileManager.default
        let descriptor = Darwin.open(lockURL.path, O_RDWR)
        if descriptor < 0 {
            if errno == ENOENT { return }
            throw PipelineRenderRecordError.transactionInProgress(phase)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw PipelineRenderRecordError.transactionInProgress(phase)
            }
            throw PipelineRenderRecordError.publicationRollbackFailed(
                String(cString: strerror(lockError))
            )
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        let transactionID = (try? String(contentsOf: lockURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard UUID(uuidString: transactionID) != nil else {
            try removeOrphanedStagingDirectories(
                dataRoot: dataRoot,
                phase: phase
            )
            try fileManager.removeItem(at: lockURL)
            return
        }
        let staging = PipelineLayout.url(PipelineLayout.rendersDir, in: dataRoot)
            .appendingPathComponent(
                ".record-\(phase)-\(transactionID)",
                isDirectory: true
            )
        let publicationURL = PipelineLayout.url(
            RenderRecordPublicationV1.artifactPath(phase: phase),
            in: dataRoot
        )
        if let publicationData = try? Data(contentsOf: publicationURL),
           let publication = try? JSONDecoder().decode(
               RenderRecordPublicationV1.self,
               from: publicationData
           ),
           publication.transactionID == transactionID,
           isValidPublication(
               publication,
               data: publicationData,
               dataRoot: dataRoot
           ) {
            try? fileManager.removeItem(at: staging)
            try fileManager.removeItem(at: lockURL)
            return
        }

        let journalURL = staging.appendingPathComponent("recovery.json")
        guard fileManager.fileExists(atPath: journalURL.path) else {
            try? fileManager.removeItem(at: staging)
            try fileManager.removeItem(at: lockURL)
            return
        }
        do {
            let journal = try JSONDecoder().decode(
                RecoveryJournal.self,
                from: Data(contentsOf: journalURL)
            )
            let publicationPath = RenderRecordPublicationV1.artifactPath(
                phase: phase
            )
            let provenancePublicationPath = RenderShotProvenancePublicationV1
                .artifactPath(phase: phase)
            let legacyPaths: Set<String> = phase == "frames"
                ? [
                    PipelineLayout.renderManifestFile(phase: phase),
                    PipelineLayout.framesManifestFile,
                    publicationPath,
                ]
                : [
                    PipelineLayout.renderManifestFile(phase: phase),
                    PipelineLayout.renderProofFile(phase: phase),
                    PipelineLayout.renderRoutingProofFile(phase: phase),
                    publicationPath,
                ]
            let requiredPaths = legacyPaths.union([provenancePublicationPath])
            let journalPaths = Set(journal.files.map(\.path))
            let additionalPaths = journalPaths.subtracting(requiredPaths)
            let isLegacyJournal = journalPaths == legacyPaths
            let isCurrentJournal = requiredPaths.isSubset(of: journalPaths)
                && additionalPaths.allSatisfy({
                    isImmutableShotProvenancePath($0, phase: phase)
                })
            guard journal.schema == RecoveryJournal.schemaVersion,
                  journal.phase == phase,
                  journalPaths.count == journal.files.count,
                  isLegacyJournal || isCurrentJournal else {
                throw PipelineRenderRecordError.publicationRollbackFailed(
                    "The recovery journal is invalid."
                )
            }
            try requireSafeLocations(
                phase: phase,
                lastFramePath: journal.lastFramePath,
                dataRoot: dataRoot
            )
            for path in additionalPaths {
                try requireSafeDataRootPath(path, dataRoot: dataRoot)
            }
            var failures: [String] = []
            for file in journal.files where file.path != publicationPath {
                do {
                    try restore(
                        file.data,
                        at: PipelineLayout.url(file.path, in: dataRoot)
                    )
                } catch {
                    failures.append("\(file.path): \(error.localizedDescription)")
                }
            }
            if let path = journal.lastFramePath {
                do {
                    try restore(
                        journal.lastFrameData,
                        at: safeProjectURL(path, dataRoot: dataRoot)
                    )
                } catch {
                    failures.append("\(path): \(error.localizedDescription)")
                }
            }
            let publication = journal.files.first {
                $0.path == publicationPath
            }
            do {
                try restore(publication?.data, at: publicationURL)
            } catch {
                failures.append("\(publicationPath): \(error.localizedDescription)")
            }
            guard failures.isEmpty else {
                throw PipelineRenderRecordError.publicationRollbackFailed(
                    failures.joined(separator: "; ")
                )
            }
            try? fileManager.removeItem(at: staging)
            try fileManager.removeItem(at: lockURL)
        } catch let error as PipelineRenderRecordError {
            throw error
        } catch {
            throw PipelineRenderRecordError.publicationRollbackFailed(
                error.localizedDescription
            )
        }
    }

    private static func isValidPublication(
        _ publication: RenderRecordPublicationV1,
        data: Data,
        dataRoot: URL
    ) -> Bool {
        do {
            try verifyPublication(
                publication,
                expectedData: data,
                dataRoot: dataRoot
            )
            return true
        } catch {
            return false
        }
    }

    private static func acquireExclusiveLock(
        transactionID: String,
        lockURL: URL,
        phase: String
    ) throws -> Int32 {
        let descriptor = Darwin.open(
            lockURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw PipelineRenderRecordError.transactionInProgress(phase)
            }
            throw PipelineRenderRecordError.publicationFailed(
                String(cString: strerror(errno))
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: lockURL)
            throw PipelineRenderRecordError.publicationFailed(
                String(cString: strerror(lockError))
            )
        }
        let data = Data(transactionID.utf8)
        var offset = 0
        var writeError: Int32?
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else {
                writeError = EIO
                return
            }
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    writeError = errno
                    return
                }
                guard written > 0 else {
                    writeError = EIO
                    return
                }
                offset += written
            }
        }
        if writeError == nil, fsync(descriptor) != 0 {
            writeError = errno
        }
        guard let writeError else {
            return descriptor
        }
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: lockURL)
        throw PipelineRenderRecordError.publicationFailed(
            String(cString: strerror(writeError))
        )
    }

    private static func removeOrphanedStagingDirectories(
        dataRoot: URL,
        phase: String
    ) throws {
        let renders = PipelineLayout.url(PipelineLayout.rendersDir, in: dataRoot)
        guard FileManager.default.fileExists(atPath: renders.path) else { return }
        let prefix = ".record-\(phase)-"
        let candidates = try FileManager.default.contentsOfDirectory(
            at: renders,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for candidate in candidates where candidate.lastPathComponent.hasPrefix(prefix) {
            let suffix = String(candidate.lastPathComponent.dropFirst(prefix.count))
            guard UUID(uuidString: suffix) != nil,
                  try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                continue
            }
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private static func restore(
        _ snapshot: Snapshot,
        publicationPath: String,
        dataRoot: URL
    ) throws {
        var failures: [String] = []
        for (path, data) in snapshot.bytesByPath where path != publicationPath {
            do {
                try restore(data, at: PipelineLayout.url(path, in: dataRoot))
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }
        if let url = snapshot.lastFrameURL {
            do {
                try restore(snapshot.lastFrameData, at: url)
            } catch {
                failures.append("\(url.path): \(error.localizedDescription)")
            }
        }
        do {
            try restore(
                snapshot.bytesByPath[publicationPath] ?? nil,
                at: PipelineLayout.url(publicationPath, in: dataRoot)
            )
        } catch {
            failures.append("\(publicationPath): \(error.localizedDescription)")
        }
        guard failures.isEmpty else {
            throw PipelineRenderRecordError.publicationRollbackFailed(
                failures.joined(separator: "; ")
            )
        }
    }

    private static func restore(_ data: Data?, at url: URL) throws {
        if let data {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func write(_ data: Data, to path: String, dataRoot: URL) throws {
        let url = PipelineLayout.url(path, in: dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func encode<T: Encodable>(
        _ value: T,
        prettyPrinted: Bool
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func validatePhase(_ phase: String) throws {
        guard ["frames", "preview", "final"].contains(phase) else {
            throw PipelineRenderRecordError.unsafePath(phase)
        }
    }

    private static func transactionPath(phase: String) -> String {
        "renders/.record-\(phase).in-progress"
    }

    private static func requireSafeLocations(
        phase: String,
        lastFramePath: String?,
        dataRoot: URL
    ) throws {
        let root = dataRoot.standardizedFileURL
        let renders = PipelineLayout.url(PipelineLayout.rendersDir, in: root)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: root.path)) == nil,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: renders.path)) == nil else {
            throw PipelineRenderRecordError.unsafePath(renders.path)
        }
        for path in [
            PipelineLayout.renderManifestFile(phase: phase),
            PipelineLayout.renderProofFile(phase: phase),
            PipelineLayout.renderRoutingProofFile(phase: phase),
            PipelineLayout.framesManifestFile,
            RenderRecordPublicationV1.artifactPath(phase: phase),
            RenderShotProvenancePublicationV1.artifactPath(phase: phase),
            transactionPath(phase: phase),
        ] {
            try requireSafeDataRootPath(path, dataRoot: root)
        }
        if let lastFramePath {
            _ = try safeProjectURL(lastFramePath, dataRoot: dataRoot)
        }
    }

    private static func safeProjectURL(
        _ path: String,
        dataRoot: URL
    ) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !NSString(string: path).isAbsolutePath,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PipelineRenderRecordError.unsafePath(path)
        }
        let home = FrameInventory.projectHome(of: dataRoot).standardizedFileURL
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: home.path)) == nil else {
            throw PipelineRenderRecordError.unsafePath(home.path)
        }
        var current = home
        for component in components {
            current.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw PipelineRenderRecordError.unsafePath(path)
            }
        }
        guard current.path.hasPrefix(home.path + "/") else {
            throw PipelineRenderRecordError.unsafePath(path)
        }
        return current
    }

    private static func requireSafeDataRootPath(
        _ path: String,
        dataRoot: URL
    ) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !NSString(string: path).isAbsolutePath,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PipelineRenderRecordError.unsafePath(path)
        }
        var current = dataRoot
        for component in components {
            current.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw PipelineRenderRecordError.unsafePath(path)
            }
        }
    }

    private static func isImmutableShotProvenancePath(
        _ path: String,
        phase: String
    ) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 5,
              components[0] == "renders",
              components[1] == "provenance",
              components[2] == Substring(phase),
              !components[3].isEmpty,
              components[3] != ".",
              components[3] != ".." else {
            return false
        }
        let suffix = ".v1.json"
        let filename = String(components[4])
        guard filename.hasSuffix(suffix) else { return false }
        let sha256 = String(filename.dropLast(suffix.count))
        return sha256.count == 64
            && sha256.allSatisfy(\.isHexDigit)
            && sha256 == sha256.lowercased()
    }
}
