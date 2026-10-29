import Foundation

public struct StoryboardBundleSnapshot: Sendable, Equatable {
    public let storyboard: StoryboardV2
    public let causality: StoryboardCausalityV2
    public let timing: StoryboardTimingV1
    public let identity: StoryboardIdentityV1
    public let references: [CanonicalArtifactReferenceV1]
    public let sketchProofs: [String: StoryboardSketchProofV1]
    public let fingerprint: String
    public let sketchProblems: [String: String]

    init(storyboard: StoryboardV2, causality: StoryboardCausalityV2, timing: StoryboardTimingV1,
                identity: StoryboardIdentityV1, references: [CanonicalArtifactReferenceV1],
                sketchProofs: [String: StoryboardSketchProofV1], fingerprint: String, sketchProblems: [String: String] = [:]) {
        self.storyboard = storyboard
        self.causality = causality
        self.timing = timing
        self.identity = identity
        self.references = references
        self.sketchProofs = sketchProofs
        self.fingerprint = fingerprint
        self.sketchProblems = sketchProblems
    }
}

public enum ProductionPlanningStoreV1 {
    public static func readScript(dataRoot: URL, treatmentBeatIDs: Set<String>, sourceBytes: [String: Data] = [:]) throws -> ScriptV1 {
        let (script, _) = try readScriptBytes(dataRoot: dataRoot)
        try script.header.requireCurrentInputs(dataRoot: dataRoot)
        try ScriptValidatorV1.validate(script, treatmentBeatIDs: treatmentBeatIDs, sourceBytes: sourceBytes)
        return script
    }

    public static func readStoryboard(dataRoot: URL, script: ScriptV1, requireVisuals: Bool = true,
                                      evidenceVerifier: StoryboardSketchEvidenceVerifier? = nil,
                                      evidenceReferences: StoryboardSketchEvidenceReferences? = nil) throws -> StoryboardBundleSnapshot {
        let (storedScript, scriptBytes) = try readScriptBytes(dataRoot: dataRoot)
        try PlanningValidation.require(storedScript == script, "storyboard.currentScript")
        let storyboardBytes = try read(StoryboardV2.currentPath, dataRoot: dataRoot)
        guard let storyboardText = String(data: storyboardBytes, encoding: .utf8) else {
            throw ProductionPlanningError.invalid("storyboard.utf8")
        }
        let storyboard = try YAMLCoding.decode(StoryboardV2.self, from: storyboardText)
        let causalityBytes = try read(StoryboardCausalityV2.currentPath, dataRoot: dataRoot)
        let causality = try JSONDecoder().decode(StoryboardCausalityV2.self, from: causalityBytes)
        let timingBytes = try read(StoryboardTimingV1.currentPath, dataRoot: dataRoot)
        let timing = try JSONDecoder().decode(StoryboardTimingV1.self, from: timingBytes)
        let identityBytes = try read(StoryboardIdentityV1.currentPath, dataRoot: dataRoot)
        let identity = try JSONDecoder().decode(StoryboardIdentityV1.self, from: identityBytes)
        let revision = storyboard.header.revision
        let archivePaths = [StoryboardV2.versionPath(revision), StoryboardCausalityV2.versionPath(revision),
                            StoryboardTimingV1.versionPath(revision), StoryboardIdentityV1.versionPath(revision)]
        let currentPaths = [StoryboardV2.currentPath, StoryboardCausalityV2.currentPath,
                            StoryboardTimingV1.currentPath, StoryboardIdentityV1.currentPath]
        let artifactBytes = [storyboardBytes, causalityBytes, timingBytes, identityBytes]
        for index in archivePaths.indices {
            try requireMirror(artifactBytes[index], versionPath: archivePaths[index], dataRoot: dataRoot)
        }
        try requireLatest(revision: revision, directory: "storyboard", prefix: "v", suffix: ".v2.yaml", dataRoot: dataRoot)
        let prior: StoryboardIdentityV1?
        if revision > 1 {
            let bytes = try read(StoryboardIdentityV1.versionPath(revision - 1), dataRoot: dataRoot)
            prior = try JSONDecoder().decode(StoryboardIdentityV1.self, from: bytes)
            try requireInput(identity.header, path: StoryboardIdentityV1.versionPath(revision - 1), bytes: bytes)
        } else { prior = nil }
        try StoryboardBundleValidator.validate(storyboard: storyboard, causality: causality, timing: timing,
            identity: identity, script: script, priorIdentity: prior, requireVisuals: requireVisuals)
        try requireInput(storyboard.header, path: ScriptV1.versionPath(script.header.revision), bytes: scriptBytes)
        try requireInput(causality.header, path: archivePaths[0], bytes: storyboardBytes)
        try requireInput(identity.header, path: archivePaths[0], bytes: storyboardBytes)
        for index in [0, 1, 3] { try requireInput(timing.header, path: archivePaths[index], bytes: artifactBytes[index]) }
        for header in [script.header, storyboard.header, causality.header, timing.header, identity.header] {
            try header.requireCurrentInputs(dataRoot: dataRoot)
        }
        var references = [script.header, storyboard.header, causality.header, timing.header, identity.header].flatMap(\.inputs)
        references.append(reference(id: "script.current", role: "core.script", path: ScriptV1.currentPath, bytes: scriptBytes))
        references.append(reference(id: "script.version", role: "core.script", path: ScriptV1.versionPath(script.header.revision), bytes: scriptBytes))
        for index in archivePaths.indices {
            for path in [archivePaths[index], currentPaths[index]] {
                references.append(reference(id: "bundle.\(index).\(path == currentPaths[index] ? "current" : "version")",
                    role: "core.storyboard-bundle", path: path, bytes: artifactBytes[index]))
            }
        }
        var proofs: [String: StoryboardSketchProofV1] = [:]
        var sketchProblems: [String: String] = [:]
        var damagedStates: [String] = []
        for shot in timing.shots {
            for moment in shot.moments {
                guard let asset = moment.asset else { continue }
                do {
                    let bytes = try read(asset.proof.path, dataRoot: dataRoot)
                    try PlanningValidation.require(FileDigest.sha256(of: bytes) == asset.proof.sha256, "storyboard.sketch.proofHash")
                    let proof = try JSONDecoder().decode(StoryboardSketchProofV1.self, from: bytes)
                    try proof.requireCurrentBytes(dataRoot: dataRoot)
                    try PlanningValidation.require(proof.projectID == storyboard.header.projectID && proof.shotID == shot.id
                        && proof.momentID == moment.id && proof.image == asset.image
                        && proof.intentSHA256 == FileDigest.sha256(of: Data(moment.intent.utf8))
                        && proof.framingSHA256 == (try shot.framing.fingerprint()), "storyboard.sketch.target")
                    if requireVisuals {
                        guard let evidenceVerifier else { throw ProductionPlanningError.invalid("storyboard.sketch.hostEvidenceVerifier") }
                        try evidenceVerifier(proof, dataRoot)
                    } else if let evidenceVerifier {
                        try evidenceVerifier(proof, dataRoot)
                    }
                    let visualReferences = [asset.image, asset.proof] + (try proof.currentByteReferences(dataRoot: dataRoot))
                        + (try evidenceReferences?(proof, dataRoot) ?? [])
                    for reference in visualReferences {
                        _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
                    }
                    proofs[asset.proof.path] = proof
                    references.append(contentsOf: visualReferences)
                } catch {
                    guard !requireVisuals else { throw error }
                    sketchProblems[moment.id] = "The sketch image or its proof is missing or changed. Replace this sketch."
                    damagedStates.append(moment.id)
                    var visited = Set<String>()
                    damagedStates += visualFileStates(image: asset.image, proof: asset.proof, dataRoot: dataRoot,
                        visited: &visited, depth: 0)
                }
            }
        }
        var byPath: [String: CanonicalArtifactReferenceV1] = [:]
        for item in references {
            if let previous = byPath[item.path] {
                try PlanningValidation.require(previous.sha256 == item.sha256, "storyboard.bundle.conflictingPath")
            } else { byPath[item.path] = item }
        }
        references = byPath.values.sorted { $0.path < $1.path }
        for item in references { _ = try ProjectLocalFile.requireHash(item.sha256, at: item.path, dataRoot: dataRoot) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var fingerprintBytes = try encoder.encode(references)
        if !damagedStates.isEmpty { fingerprintBytes.append(try encoder.encode(damagedStates.sorted())) }
        let fingerprint = FileDigest.sha256(of: fingerprintBytes)
        return StoryboardBundleSnapshot(storyboard: storyboard, causality: causality, timing: timing,
            identity: identity, references: references, sketchProofs: proofs, fingerprint: fingerprint, sketchProblems: sketchProblems)
    }

    public static func readShotPlanning(dataRoot: URL, storyboard: StoryboardBundleSnapshot) throws -> ShotPlanningDraftV1 {
        let bytes = try read(ShotPlanningDraftV1.currentPath, dataRoot: dataRoot)
        let value = try JSONDecoder().decode(ShotPlanningDraftV1.self, from: bytes)
        try ShotPlanningValidatorV1.validate(value, timing: storyboard.timing)
        try requireMirror(bytes, versionPath: ShotPlanningDraftV1.versionPath(value.header.revision), dataRoot: dataRoot)
        try requireLatest(revision: value.header.revision, directory: "shot-planning", prefix: "v", suffix: ".v1.json", dataRoot: dataRoot)
        for artifact in storyboard.references where artifact.role == "core.storyboard-bundle" {
            try PlanningValidation.require(value.header.inputs.contains { $0.path == artifact.path && $0.sha256 == artifact.sha256 }, "shotPlanning.bundleReference")
        }
        try value.header.requireCurrentInputs(dataRoot: dataRoot)
        for shot in value.shots {
            for source in [shot.source, shot.camera.sceneReference, shot.camera.spatialState, shot.camera.spatialDerivation].compactMap({ $0 }) {
                _ = try ProjectLocalFile.requireHash(source.sha256, at: source.path, dataRoot: dataRoot)
            }
        }
        return value
    }

    private static func visualFileStates(image: CanonicalArtifactReferenceV1, proof reference: CanonicalArtifactReferenceV1,
        dataRoot: URL, visited: inout Set<String>, depth: Int) -> [String] {
        guard depth < 64, visited.insert(reference.path).inserted else { return [reference.path + ":cycle-or-depth"] }
        var states = [visualFileState(image.path, dataRoot: dataRoot), visualFileState(reference.path, dataRoot: dataRoot)]
        guard let bytes = try? read(reference.path, dataRoot: dataRoot),
              let proof = try? JSONDecoder().decode(StoryboardSketchProofV1.self, from: bytes) else { return states }
        states += proof.sourceReferences.map { visualFileState($0.path, dataRoot: dataRoot) }
        if case .reassigned(let original, let originalProof, _) = proof.source {
            states += visualFileStates(image: original, proof: originalProof, dataRoot: dataRoot, visited: &visited, depth: depth + 1)
        }
        return states
    }

    private static func visualFileState(_ path: String, dataRoot: URL) -> String {
        guard let url = try? ProjectLocalFile.resolve(path, dataRoot: dataRoot),
              let hash = try? FileDigest.sha256(of: url) else { return path + ":unavailable" }
        return path + ":" + hash
    }

    private static func readScriptBytes(dataRoot: URL) throws -> (ScriptV1, Data) {
        let bytes = try read(ScriptV1.currentPath, dataRoot: dataRoot)
        let value = try JSONDecoder().decode(ScriptV1.self, from: bytes)
        try PlanningValidation.require(value.schema == ScriptV1.schemaVersion, "script.schema")
        try value.header.validate()
        try requireMirror(bytes, versionPath: ScriptV1.versionPath(value.header.revision), dataRoot: dataRoot)
        try requireLatest(revision: value.header.revision, directory: "script", prefix: "v", suffix: ".v1.json", dataRoot: dataRoot)
        return (value, bytes)
    }

    private static func read(_ path: String, dataRoot: URL) throws -> Data {
        try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
    }

    private static func requireMirror(_ bytes: Data, versionPath: String, dataRoot: URL) throws {
        guard bytes == (try read(versionPath, dataRoot: dataRoot)) else { throw ProductionPlanningError.stale(versionPath) }
    }

    private static func requireInput(_ header: PlanningArtifactHeaderV1, path: String, bytes: Data) throws {
        let hash = FileDigest.sha256(of: bytes)
        try PlanningValidation.require(header.inputs.contains { $0.path == path && $0.sha256 == hash }, "bundle.input.\(path)")
    }

    private static func reference(id: String, role: String, path: String, bytes: Data) -> CanonicalArtifactReferenceV1 {
        CanonicalArtifactReferenceV1(id: id, role: role, path: path, sha256: FileDigest.sha256(of: bytes))
    }

    private static func requireLatest(revision: Int, directory: String, prefix: String, suffix: String, dataRoot: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: dataRoot.appendingPathComponent(directory).path)
        let versions = names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            return Int(name.dropFirst(prefix.count).dropLast(suffix.count))
        }
        try PlanningValidation.require(versions.max() == revision, "bundle.latestRevision")
    }
}
