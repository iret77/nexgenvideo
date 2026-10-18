import Foundation
import NexGenEngine

@MainActor
enum PipelineStoryboardBundleWriter {
    struct NativeShotIdentity {
        let shotID: String
        fileprivate init() { shotID = "shot-" + UUID().uuidString.lowercased() }
    }

    static func allocateNativeShotIdentity() -> NativeShotIdentity { NativeShotIdentity() }

    struct Proposal: Codable, Sendable {
        let summary: String
        let steps: [StoryboardV2.StoryStep]
        let bindings: [StoryboardCausalityV2.Binding]
        let timebase: RationalTimebaseV1
        let mode: Mode
        let rangeStartTicks: Int64
        let rangeDurationTicks: Int64
        let audio: StoryboardTimingV1.AudioBinding?
        let shots: [ShotProposal]
    }

    struct ShotProposal: Codable, Sendable {
        let id: String?
        let primaryStepID: String
        let additionalStepIDs: [String]
        let startTicks: Int64
        let durationTicks: Int64
        let cameraID: String?
        let framing: StoryboardTimingV1.FramingIntent
        let moments: [StoryboardTimingV1.Moment]
    }

    static func write(_ proposal: Proposal, origin: PlanningArtifactHeaderV1.Origin,
                      access: PipelinePlanningWriteAccess,
                      nativeIdentities: [NativeShotIdentity] = [],
                      nativeReassignments: [PipelineStoryboardImageReassignment.Prepared] = []) throws -> StoryboardBundleSnapshot {
        guard access.phase == "storyboard" else { throw GateBlocked("Storyboard has a different phase owner.") }
        let root = access.dataRoot
        let script = try PlanningWriterIO.script(dataRoot: root)
        if access.workflow.packID == "musicvideo" {
            let range = try PlanningWriterIO.read(PlaybackRangeV1.self, at: PlaybackRangeV1.currentPath, dataRoot: root)
            try range.validate()
            try range.header.requireCurrentInputs(dataRoot: root)
            guard proposal.timebase == range.timebase, proposal.rangeStartTicks == range.startTicks,
                  proposal.rangeDurationTicks == range.durationTicks else {
                throw GateBlocked("Storyboard timing must preserve the playback range selected in Brief.")
            }
        }
        let revision = try PlanningWriterIO.nextRevision(directory: "storyboard", suffix: ".v2.yaml", dataRoot: root)
        let prior: StoryboardIdentityV1?
        if revision > 1 {
            let previous = try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
            guard previous.storyboard.header.revision == revision - 1 else {
                throw GateBlocked("Storyboard history changed. Reopen its current revision.")
            }
            prior = previous.identity
        } else { prior = nil }
        let scriptReference = try PlanningWriterIO.reference(ScriptV1.versionPath(script.header.revision),
            id: "script", role: "core.script", dataRoot: root)
        let header = PlanningArtifactHeaderV1(projectID: script.header.projectID, revision: revision,
            origin: origin, inputs: [scriptReference])
        let board = StoryboardV2(header: header, summary: proposal.summary, steps: proposal.steps)
        let boardBytes = Data(try YAMLCoding.encode(board).utf8)
        let boardReference = PlanningWriterIO.reference(StoryboardV2.versionPath(revision), id: "storyboard",
            role: "core.storyboard-bundle", bytes: boardBytes)
        let causalHeader = PlanningArtifactHeaderV1(projectID: header.projectID, revision: revision,
            origin: origin, inputs: [scriptReference, boardReference])
        let causality = StoryboardCausalityV2(header: causalHeader, bindings: proposal.bindings)
        let causalityBytes = try PlanningWriterIO.json(causality)
        let causalityReference = PlanningWriterIO.reference(StoryboardCausalityV2.versionPath(revision),
            id: "storyboard.causality", role: "core.storyboard-bundle", bytes: causalityBytes)
        var identityInputs = [boardReference]
        if let prior {
            identityInputs.append(try PlanningWriterIO.reference(StoryboardIdentityV1.versionPath(prior.header.revision),
                id: "storyboard.prior-identity", role: "core.storyboard-identity-history", dataRoot: root))
        }
        var entries = prior?.entries ?? []
        let priorEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.shotID, $0) })
        guard Set(proposal.steps.map(\.id)).count == proposal.steps.count else {
            throw GateBlocked("Storyboard step IDs must be unique.")
        }
        let steps = Dictionary(uniqueKeysWithValues: proposal.steps.map { ($0.id, $0) })
        let allocated = Set(nativeIdentities.map(\.shotID))
        guard allocated.count == nativeIdentities.count else { throw GateBlocked("Native shot identities must be unique.") }
        var consumed = Set<String>()
        var shots: [StoryboardTimingV1.PlannedShot] = []
        var retained = Set<String>()
        for shot in proposal.shots {
            guard let step = steps[shot.primaryStepID] else { throw GateBlocked("A planned shot has no Storyboard step.") }
            let actionHash = FileDigest.sha256(of: Data(step.action.utf8))
            let id: String
            if let existingID = shot.id {
                if allocated.contains(existingID) {
                    guard priorEntries[existingID] == nil, consumed.insert(existingID).inserted else {
                        throw GateBlocked("A native shot identity was already used.")
                    }
                    entries.append(.init(shotID: existingID, primaryStepID: shot.primaryStepID,
                        actionSHA256: actionHash, introducedRevision: revision))
                } else {
                    guard let old = priorEntries[existingID], old.retiredRevision == nil,
                          old.primaryStepID == shot.primaryStepID, old.actionSHA256 == actionHash else {
                        throw GateBlocked("A changed or retired action needs a new planned-shot identity. Omit its shot ID to create one.")
                    }
                }
                id = existingID
            } else {
                id = "shot-" + UUID().uuidString.lowercased()
                entries.append(.init(shotID: id, primaryStepID: shot.primaryStepID,
                    actionSHA256: actionHash, introducedRevision: revision))
            }
            guard retained.insert(id).inserted else { throw GateBlocked("A planned shot occurs more than once.") }
            shots.append(.init(id: id, primaryStepID: shot.primaryStepID, additionalStepIDs: shot.additionalStepIDs,
                startTicks: shot.startTicks, durationTicks: shot.durationTicks, cameraID: shot.cameraID,
                framing: shot.framing, moments: shot.moments))
        }
        guard consumed == allocated else { throw GateBlocked("Every allocated native shot identity must be published exactly once.") }
        for reassignment in nativeReassignments {
            guard let shot = shots.first(where: { $0.id == reassignment.targetShotID }),
                  let moment = shot.moments.first(where: { $0.id == reassignment.targetMomentID }),
                  moment.asset == reassignment.asset else {
                throw GateBlocked("A native sketch reassignment does not match its target shot and moment.")
            }
        }
        entries = entries.map { old in
            guard old.retiredRevision == nil, !retained.contains(old.shotID) else { return old }
            return .init(shotID: old.shotID, primaryStepID: old.primaryStepID, actionSHA256: old.actionSHA256,
                introducedRevision: old.introducedRevision, retiredRevision: revision)
        }
        let identity = StoryboardIdentityV1(header: .init(projectID: header.projectID, revision: revision,
            origin: origin, inputs: identityInputs), entries: entries)
        let identityBytes = try PlanningWriterIO.json(identity)
        let identityReference = PlanningWriterIO.reference(StoryboardIdentityV1.versionPath(revision),
            id: "storyboard.identity", role: "core.storyboard-bundle", bytes: identityBytes)
        let timing = StoryboardTimingV1(header: .init(projectID: header.projectID, revision: revision,
            origin: origin, inputs: [scriptReference, boardReference, causalityReference, identityReference]),
            timebase: proposal.timebase, mode: proposal.mode, rangeStartTicks: proposal.rangeStartTicks,
            rangeDurationTicks: proposal.rangeDurationTicks, audio: proposal.audio, shots: shots)
        try StoryboardBundleValidator.validate(storyboard: board, causality: causality, timing: timing,
            identity: identity, script: script, priorIdentity: prior, requireVisuals: false)
        let timingBytes = try PlanningWriterIO.json(timing)
        let versionPaths = [StoryboardV2.versionPath(revision), StoryboardCausalityV2.versionPath(revision),
                            StoryboardIdentityV1.versionPath(revision), StoryboardTimingV1.versionPath(revision)]
        let currentPaths = [StoryboardV2.currentPath, StoryboardCausalityV2.currentPath,
                            StoryboardIdentityV1.currentPath, StoryboardTimingV1.currentPath]
        let bytes = [boardBytes, causalityBytes, identityBytes, timingBytes]
        let bundleFiles = versionPaths.indices.flatMap { [(versionPaths[$0], bytes[$0]), (currentPaths[$0], bytes[$0])] }
        let reassignmentFiles = nativeReassignments.flatMap(\.files)
        for file in reassignmentFiles {
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(file.path).path) else {
                throw GateBlocked("Native sketch reassignment receipts are immutable.")
            }
        }
        let files = bundleFiles + reassignmentFiles
        guard Set(files.map { $0.0 }).count == files.count else { throw GateBlocked("Storyboard publication paths must be unique.") }
        try access.publish(files) {
            let snapshot = try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
            for proof in snapshot.sketchProofs.values {
                try PipelineStoryboardSketchEvidence.requireCurrent(proof, root)
            }
        }
        return try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
    }

    static func proposal(from snapshot: StoryboardBundleSnapshot,
                         replacing momentID: String, in shotID: String,
                         with asset: StoryboardTimingV1.SketchAsset) -> Proposal {
        let timing = snapshot.timing
        return Proposal(summary: snapshot.storyboard.summary, steps: snapshot.storyboard.steps,
            bindings: snapshot.causality.bindings, timebase: timing.timebase, mode: timing.mode,
            rangeStartTicks: timing.rangeStartTicks, rangeDurationTicks: timing.rangeDurationTicks,
            audio: timing.audio, shots: timing.shots.map { shot in
                ShotProposal(id: shot.id, primaryStepID: shot.primaryStepID, additionalStepIDs: shot.additionalStepIDs,
                    startTicks: shot.startTicks, durationTicks: shot.durationTicks, cameraID: shot.cameraID,
                    framing: shot.framing, moments: shot.moments.map { moment in
                        guard shot.id == shotID, moment.id == momentID else { return moment }
                        return .init(id: moment.id, offsetTicks: moment.offsetTicks, intent: moment.intent, asset: asset)
                    })
            })
    }

    static func attachImage(from url: URL, shotID: String, momentID: String,
                            expectedFingerprint: String, editor: EditorViewModel) async throws -> StoryboardBundleSnapshot {
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else {
            throw GateBlocked("Open a production project first.")
        }
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "storyboard") else {
            throw GateBlocked("Wait for the current production job to finish before assigning a sketch.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "storyboard")
        let snapshot = try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
        guard snapshot.fingerprint == expectedFingerprint,
              let shot = snapshot.timing.shots.first(where: { $0.id == shotID }),
              let moment = shot.moments.first(where: { $0.id == momentID }) else {
            throw GateBlocked("The Storyboard changed. Select the current shot and sketch again.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              ProjectMediaExtensions.images.contains(url.pathExtension.lowercased()) else {
            throw GateBlocked("Choose a regular image file for this sketch.")
        }
        if editor.projectURL != nil {
            guard let key = editor.openWorkingCopyKey else { throw GateBlocked("Reopen the project before assigning a sketch.") }
            try ProjectWorkingCopy.markDirty(key: key)
        }
        let sourceBytes = try Data(contentsOf: url)
        _ = try FrameRasterizer.loadImage(at: url)
        let hash = FileDigest.sha256(of: sourceBytes)
        let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "storyboard/sketches",
            leaf: "\(UUID().uuidString.lowercased()).\(url.pathExtension.lowercased())", dataRoot: root)
        _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: root)
        let destination = root.appendingPathComponent(path)
        try sourceBytes.write(to: destination, options: .atomic)
        let image = CanonicalArtifactReferenceV1(id: "sketch.\(hash)", role: "core.storyboard-sketch", path: path, sha256: hash)
        let receiptID = UUID().uuidString.lowercased()
        let proof = StoryboardSketchProofV1(projectID: snapshot.storyboard.header.projectID, shotID: shotID,
            momentID: momentID, intentSHA256: FileDigest.sha256(of: Data(moment.intent.utf8)),
            framingSHA256: try shot.framing.fingerprint(), image: image,
            source: .uploaded(original: image, selectionReceiptID: receiptID))
        try PipelineStoryboardSketchEvidence.recordSelection(proof: proof, receiptID: receiptID,
            originalName: url.lastPathComponent, expectedFingerprint: expectedFingerprint, dataRoot: root)
        let proofPath = "storyboard/sketch-proofs/\(receiptID).v1.json"
        let proofBytes = try PlanningWriterIO.json(proof)
        _ = try ProjectLocalFile.ensureDirectory("storyboard/sketch-proofs", dataRoot: root)
        try proofBytes.write(to: root.appendingPathComponent(proofPath), options: .atomic)
        let asset = StoryboardTimingV1.SketchAsset(image: image, proof: PlanningWriterIO.reference(proofPath,
            id: "sketch-proof.\(receiptID)", role: "core.storyboard-sketch-proof", bytes: proofBytes))
        try access.revalidate()
        guard try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false).fingerprint == expectedFingerprint,
              editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease) else {
            throw GateBlocked("The Storyboard changed before sketch assignment. The imported image remains a candidate.")
        }
        let result = try write(proposal(from: snapshot, replacing: momentID, in: shotID, with: asset), origin: .userRevision, access: access)
        return result
    }
}

enum PipelineStoryboardSketchEvidence {
    private struct Selection: Codable {
        let schema: String
        let receiptID: String
        let originalName: String
        let expectedFingerprint: String
        let proof: StoryboardSketchProofV1
    }

    static func selectionFile(proof: StoryboardSketchProofV1, receiptID: String,
                              originalName: String, expectedFingerprint: String) throws -> (path: String, bytes: Data) {
        let path = try selectionPath(receiptID)
        let receipt = Selection(schema: "storyboard-sketch-selection/v1", receiptID: receiptID,
            originalName: originalName, expectedFingerprint: expectedFingerprint, proof: proof)
        return (path, try PlanningWriterIO.json(receipt))
    }

    static func recordSelection(proof: StoryboardSketchProofV1, receiptID: String,
                                originalName: String, expectedFingerprint: String, dataRoot: URL) throws {
        let file = try selectionFile(proof: proof, receiptID: receiptID,
            originalName: originalName, expectedFingerprint: expectedFingerprint)
        let url = dataRoot.appendingPathComponent(file.path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw GateBlocked("Sketch selection receipts are immutable.") }
        _ = try ProjectLocalFile.ensureDirectory("storyboard/sketch-selection-receipts", dataRoot: dataRoot)
        try file.bytes.write(to: url, options: .atomic)
    }

    static func requireCurrent(_ proof: StoryboardSketchProofV1, _ dataRoot: URL) throws {
        try requireCurrent(proof, dataRoot, visited: [])
    }

    private static func requireCurrent(_ proof: StoryboardSketchProofV1, _ dataRoot: URL, visited: Set<String>) throws {
        try proof.requireCurrentBytes(dataRoot: dataRoot)
        switch proof.source {
        case .uploaded(_, let receiptID):
            let receipt = try PlanningWriterIO.read(Selection.self, at: selectionPath(receiptID), dataRoot: dataRoot)
            guard receipt.schema == "storyboard-sketch-selection/v1", receipt.receiptID == receiptID,
                  receipt.proof == proof, !receipt.originalName.isEmpty,
                  receipt.expectedFingerprint.count == 64 else { throw GateBlocked("The sketch's native selection receipt is invalid.") }
        case .reassigned(let originalImage, let originalProof, let receiptID):
            guard !visited.contains(originalProof.path), originalImage.sha256 == proof.image.sha256 else {
                throw GateBlocked("The sketch reassignment history is invalid.")
            }
            let receipt = try PlanningWriterIO.read(Selection.self, at: selectionPath(receiptID), dataRoot: dataRoot)
            guard receipt.schema == "storyboard-sketch-selection/v1", receipt.receiptID == receiptID,
                  receipt.proof == proof, !receipt.originalName.isEmpty, receipt.expectedFingerprint.count == 64 else {
                throw GateBlocked("The sketch's native reassignment receipt is invalid.")
            }
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(originalProof.sha256, at: originalProof.path, dataRoot: dataRoot))
            let original = try JSONDecoder().decode(StoryboardSketchProofV1.self, from: bytes)
            guard original.projectID == proof.projectID, original.image == originalImage else {
                throw GateBlocked("The sketch reassignment does not preserve its original image provenance.")
            }
            try requireCurrent(original, dataRoot, visited: visited.union([originalProof.path]))
        case .generated, .sourceFrame, .externalConfirmed, .spatialDerived:
            throw GateBlocked("This sketch needs its original verified host provenance before it can be assigned.")
        }
    }

    private static func selectionPath(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
            throw GateBlocked("The sketch selection receipt is invalid.")
        }
        return "storyboard/sketch-selection-receipts/\(id).v1.json"
    }
}
