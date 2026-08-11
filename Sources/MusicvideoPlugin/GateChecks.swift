import Foundation
import NexGenEngine

/// Deterministic hard-gate preconditions for the musicvideo pack. These run (non-LLM) before a gate
/// can be approved, so the agent can never advance a phase whose real artifact is missing — the port
/// of the predecessor's analysis→render `require()` chain.
enum MusicvideoGateChecks {
    private struct MeasuredSection {
        let index: Int
        let start: Double
        let end: Double
        let label: String
    }

    private static func projectMeta(dataRoot: URL, phase: String) throws -> ProjectMeta {
        do {
            return try YAMLArtifactStore(dataRoot: dataRoot).load(
                ProjectMeta.self,
                at: PipelineLayout.projectFile
            )
        } catch {
            throw GateBlocked(
                "Can't approve \"\(phase)\": project.yaml is missing or invalid (\(error))."
            )
        }
    }

    private static func requireProjectIdentity(
        _ artifactProject: String,
        phase: String,
        dataRoot: URL
    ) throws {
        let meta = try projectMeta(dataRoot: dataRoot, phase: phase)
        guard artifactProject == meta.project else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": its artifact belongs to project "
                    + "\"\(artifactProject)\", not \"\(meta.project)\"."
            )
        }
    }

    private static func promptContains(
        _ prompt: String,
        requirements: [String]
    ) -> Bool {
        ComplianceLinter.lintLockedDirectives(
            prompt,
            lockedDirectives: requirements
        ).isEmpty
    }

    private static func existingProjectFile(
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
                    || candidate.path.hasPrefix(home.path + "/")
            else { continue }
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

    private static func requireProjectFiles(
        _ paths: [String],
        phase: String,
        label: String,
        dataRoot: URL
    ) throws {
        let invalid = paths.filter {
            existingProjectFile($0, dataRoot: dataRoot) == nil
        }
        guard invalid.isEmpty else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": \(invalid.count) \(label) path(s) are "
                    + "missing or outside the project (e.g. "
                    + "\(invalid.prefix(3).joined(separator: ", ")))."
            )
        }
    }

    private static func requireProjectImages(
        _ paths: [String],
        phase: String,
        label: String,
        dataRoot: URL
    ) throws {
        try requireProjectFiles(
            paths,
            phase: phase,
            label: label,
            dataRoot: dataRoot
        )
        let invalid = paths.filter {
            guard let url = existingProjectFile($0, dataRoot: dataRoot) else {
                return true
            }
            return !ProjectMediaExtensions.images.contains(
                url.pathExtension.lowercased()
            )
        }
        guard invalid.isEmpty else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": \(invalid.count) \(label) path(s) are "
                    + "not images (e.g. \(invalid.prefix(3).joined(separator: ", ")))."
            )
        }
    }

    private static func assetProof(
        scope: String,
        phase: String,
        dataRoot: URL
    ) throws -> PipelineAssetProof {
        let proof: PipelineAssetProof
        do {
            proof = try loadPipelineAssetProof(
                dataRoot: dataRoot,
                scope: scope
            )
        } catch {
            throw GateBlocked(
                "Can't approve \"\(phase)\": \(scope) generation provenance is invalid "
                    + "(\(error))."
            )
        }
        let meta = try projectMeta(dataRoot: dataRoot, phase: phase)
        guard proof.schema == pipelineAssetProofSchemaVersion,
              proof.project == meta.project,
              proof.scope == scope else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": \(scope) generation provenance has the "
                    + "wrong project, scope, or schema."
            )
        }
        return proof
    }

    private static func requireGeneratedProjectFiles(
        _ paths: [String],
        scope: String,
        phase: String,
        dataRoot: URL
    ) throws {
        let proof = try assetProof(
            scope: scope,
            phase: phase,
            dataRoot: dataRoot
        )
        let invalid = paths.filter { path in
            guard let entry = proof.entries[path],
                  entry.path == path,
                  !entry.providerPrompt.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  !entry.generationModel.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  !entry.sourceMediaId.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  let url = existingProjectFile(path, dataRoot: dataRoot)
            else { return true }
            return sha256(url) != entry.sha256
        }
        guard invalid.isEmpty else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": \(invalid.count) generated \(scope) "
                    + "asset(s) lack current host-recorded prompt/model provenance "
                    + "(e.g. \(invalid.prefix(3).joined(separator: ", ")))."
            )
        }
    }

    private static func analysisObject(dataRoot: URL, phase: String) throws -> [String: Any] {
        guard let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": the measured analysis artifact is missing or invalid."
            )
        }
        return object
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func measuredSections(dataRoot: URL, phase: String) throws -> [MeasuredSection] {
        let object = try analysisObject(dataRoot: dataRoot, phase: phase)
        let sections = object["sections"] as? [[String: Any]] ?? []
        let labels = (object["interpretation"] as? [String: Any])?["section_labels"]
            as? [[String: Any]] ?? []
        var labelByIndex: [Int: String] = [:]
        for item in labels {
            guard let index = integer(item["index"]),
                  let label = item["label"] as? String,
                  labelByIndex[index] == nil else {
                throw GateBlocked(
                    "Can't approve \"\(phase)\": analysis interpretation contains "
                        + "a missing or duplicate section label index."
                )
            }
            labelByIndex[index] = label
        }
        let measured = sections.compactMap { section -> MeasuredSection? in
            guard let index = integer(section["index"]),
                  let start = number(section["start"]),
                  let end = number(section["end"]),
                  end > start,
                  let label = labelByIndex[index],
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return MeasuredSection(index: index, start: start, end: end, label: label)
        }
        guard measured.count == sections.count,
              measured.count == labels.count,
              !measured.isEmpty else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": analysis sections and their persisted "
                    + "interpretation don't form one complete measured timeline."
            )
        }
        return measured.sorted { $0.index < $1.index }
    }

    private static func sha256(_ url: URL) -> String? {
        try? FileDigest.sha256(of: url)
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sameProjectPath(
        _ lhs: String,
        _ rhs: String,
        dataRoot: URL
    ) -> Bool {
        guard let left = existingProjectFile(lhs, dataRoot: dataRoot),
              let right = existingProjectFile(rhs, dataRoot: dataRoot) else {
            return false
        }
        return left == right
    }

    private static func sameProjectPathOrBothEmpty(
        _ lhs: String,
        _ rhs: String,
        dataRoot: URL
    ) -> Bool {
        if normalized(lhs).isEmpty, normalized(rhs).isEmpty {
            return true
        }
        return sameProjectPath(lhs, rhs, dataRoot: dataRoot)
    }

    private static func currentVersionMatches(
        current: String,
        versioned: String,
        phase: String,
        dataRoot: URL
    ) throws {
        let currentURL = PipelineLayout.url(current, in: dataRoot)
        let versionURL = PipelineLayout.url(versioned, in: dataRoot)
        guard let currentData = try? Data(contentsOf: currentURL),
              let versionData = try? Data(contentsOf: versionURL),
              currentData == versionData else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": \(current) is not the exact current "
                    + "copy of \(versioned). Rebuild the phase through its typed writer."
            )
        }
    }

    private static func renderInputIsCurrent(
        _ proof: RenderInputProof?,
        dataRoot: URL
    ) -> Bool {
        guard let proof,
              let url = existingProjectFile(
                proof.path,
                dataRoot: dataRoot
              ) else {
            return false
        }
        return sha256(url) == proof.sha256
    }

    private static func renderInputsAreCurrent(
        _ proof: RenderProofEntry,
        dataRoot: URL
    ) -> Bool {
        let optional = [
            proof.sourceVideo,
            proof.startFrame,
            proof.endFrame,
        ]
        let collections = proof.referenceImages
            + proof.referenceVideos
            + proof.referenceAudio
        return optional.compactMap { $0 }.allSatisfy {
            renderInputIsCurrent($0, dataRoot: dataRoot)
        } && collections.allSatisfy {
            renderInputIsCurrent($0, dataRoot: dataRoot)
        }
    }

    private static func exactRenderReferences(
        _ actual: [RenderInputProof],
        expected: [String],
        dataRoot: URL
    ) -> Bool {
        guard Set(actual.map(\.path)).count == actual.count,
              actual.count == expected.count else {
            return false
        }
        return expected.allSatisfy { expectedPath in
            actual.contains {
                sameProjectPath(
                    $0.path,
                    expectedPath,
                    dataRoot: dataRoot
                )
            }
        }
    }

    private static func renderConditioningMatches(
        shot: Shot,
        proof: RenderProofEntry,
        shotlist: Shotlist,
        manifest: RenderManifest,
        frames: FramesManifest?,
        dataRoot: URL
    ) -> Bool {
        guard renderInputsAreCurrent(proof, dataRoot: dataRoot),
              proof.referenceVideos.isEmpty,
              proof.referenceAudio.isEmpty else {
            return false
        }
        if shot.sourceMode == .aiEnhanced {
            guard let sourcePath = shot.sourcePath,
                  let source = proof.sourceVideo else {
                return false
            }
            return sameProjectPath(
                source.path,
                sourcePath,
                dataRoot: dataRoot
            )
                && proof.startFrame == nil
                && proof.endFrame == nil
                && proof.referenceImages.isEmpty
        }
        guard proof.sourceVideo == nil else { return false }
        if shot.seedanceInputMode == .reference {
            guard proof.startFrame == nil,
                  proof.endFrame == nil,
                  let plan = MusicvideoReferencePlanProvider()
                    .planReferences(
                        dataRoot: dataRoot,
                        shotId: shot.id
                    ) else {
                return false
            }
            return exactRenderReferences(
                proof.referenceImages,
                expected: plan.refs.map(\.path),
                dataRoot: dataRoot
            )
        }
        guard proof.referenceImages.isEmpty else { return false }
        let expectedStart: String?
        if shot.chainWithPreviousEnd {
            guard let predecessor = ChainContinuity.chainPredecessor(
                shotlist,
                shotId: shot.id
            ) else {
                return false
            }
            expectedStart = manifest.entries[predecessor]?.lastFramePath
        } else {
            expectedStart = frames?.shot(shot.id)?.frames.first {
                $0.role == "start"
            }?.path
        }
        let expectedEnd = frames?.shot(shot.id)?.frames.first {
            $0.role == "end"
        }?.path
        switch shot.keyframeStrategy {
        case .none:
            if shot.chainWithPreviousEnd {
                guard let expectedStart,
                      let actualStart = proof.startFrame else {
                    return false
                }
                return sameProjectPath(
                    actualStart.path,
                    expectedStart,
                    dataRoot: dataRoot
                ) && proof.endFrame == nil
            }
            return proof.startFrame == nil && proof.endFrame == nil
        case .start:
            guard let expectedStart,
                  let actualStart = proof.startFrame else {
                return false
            }
            return sameProjectPath(
                actualStart.path,
                expectedStart,
                dataRoot: dataRoot
            ) && proof.endFrame == nil
        case .startEnd:
            guard let expectedStart,
                  let expectedEnd,
                  let actualStart = proof.startFrame,
                  let actualEnd = proof.endFrame else {
                return false
            }
            return sameProjectPath(
                actualStart.path,
                expectedStart,
                dataRoot: dataRoot
            ) && sameProjectPath(
                actualEnd.path,
                expectedEnd,
                dataRoot: dataRoot
            )
        }
    }

    static func requireProjectTrack(dataRoot: URL) throws {
        do {
            _ = try MusicvideoAnalysisRunner.locateSong(dataRoot: dataRoot)
        } catch {
            throw GateBlocked(
                "Can't approve \"project_init\": attach exactly one decodable track first."
            )
        }
    }

    /// The `analysis` gate is approvable only when a real analysis artifact exists with genuine
    /// rhythm data — a non-empty `beats` AND `downbeats` list and a positive duration. This is what
    /// stops the agent from "hearing" a structure it never measured: no artifact, or an empty/degenerate
    /// one, blocks approval with an actionable message pointing at `run_phase("analysis")`.
    static func requireRealAnalysis(dataRoot: URL) throws {
        guard let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot) else {
            throw GateBlocked(
                "Can't approve \"analysis\": there isn't exactly one song in audio/ to analyse. "
                    + "Attach the track first, then run run_phase(\"analysis\").")
        }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw GateBlocked(
                "Can't approve \"analysis\": no analysis artifact yet. Run run_phase(\"analysis\") — it "
                    + "decodes the song and writes real beats/downbeats. Never describe the song's "
                    + "structure from listening; it must be measured.")
        }
        let beats = (obj["beats"] as? [Any])?.count ?? 0
        let downbeats = (obj["downbeats"] as? [Any])?.count ?? 0
        let duration = (obj["duration_s"] as? NSNumber)?.doubleValue ?? 0
        let bpm = number(obj["bpm"]) ?? 0
        let currentSong: URL
        do {
            currentSong = try MusicvideoAnalysisRunner.locateSong(dataRoot: dataRoot)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        } catch {
            throw GateBlocked(
                "Can't approve \"analysis\": attach exactly one decodable track first."
            )
        }
        guard obj["schema"] as? String == analysisSchemaVersion,
              let project = obj["project"] as? String,
              let songPath = obj["song_path"] as? String,
              let artifactSong = existingProjectFile(
                songPath,
                dataRoot: dataRoot
              ),
              artifactSong == currentSong,
              let recordedSongHash = obj["song_sha256"] as? String,
              sha256(currentSong) == recordedSongHash,
              beats > 0,
              downbeats > 0,
              duration > 0,
              bpm > 0 else {
            throw GateBlocked(
                "Can't approve \"analysis\": the artifact has invalid identity, song, "
                    + "schema, or rhythm data (beats=\(beats), downbeats=\(downbeats), "
                    + "duration=\(duration)s, bpm=\(bpm)). Re-run "
                    + "run_phase(\"analysis\") on a decodable song.")
        }
        try requireProjectIdentity(project, phase: "analysis", dataRoot: dataRoot)
        for key in ["beats", "downbeats"] {
            guard let raw = obj[key] as? [Any] else {
                throw GateBlocked(
                    "Can't approve \"analysis\": \(key) isn't a measured numeric list."
                )
            }
            let values = raw.compactMap(number)
            guard values.count == raw.count,
                  values.allSatisfy({ $0 >= 0 && $0 <= duration }),
                  zip(values, values.dropFirst()).allSatisfy({
                      $0.0 < $0.1
                  }) else {
                throw GateBlocked(
                    "Can't approve \"analysis\": \(key) must be strictly increasing "
                        + "and stay within the measured song duration."
                )
            }
        }
        // A2 gate: the DSP measures the grid, but the phase isn't done until A2 has interpreted it.
        let sections = obj["sections"] as? [[String: Any]] ?? []
        let interpretation = obj["interpretation"] as? [String: Any]
        let sectionLabels = interpretation?["section_labels"] as? [[String: Any]] ?? []
        let multiplier = (obj["tempo_multiplier"] as? NSNumber)?.doubleValue ?? .nan
        guard [0.5, 1.0, 2.0].contains(where: {
            abs($0 - multiplier) < 0.000_001
        }) else {
            throw GateBlocked(
                "Can't approve \"analysis\" yet: tempo_multiplier must be explicitly set "
                    + "to 0.5, 1, or 2 with write_analysis_interpretation."
            )
        }
        guard !sections.isEmpty, sectionLabels.count == sections.count else {
            throw GateBlocked(
                "Can't approve \"analysis\" yet: the measured sections aren't interpreted. Complete A2 — "
                    + "settle the tempo multiplier and call write_analysis_interpretation (one label per "
                    + "measured section) — then approve. The DSP measures the grid; A2 names it.")
        }
        let measuredIndexes = Set(sections.compactMap { integer($0["index"]) })
        let labeledIndexes = Set(sectionLabels.compactMap { label -> Int? in
            guard let index = integer(label["index"]),
                  let name = label["label"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let confidenceValue = label["confidence"],
                  let confidence = (confidenceValue as? NSNumber)?.doubleValue
                    ?? (confidenceValue as? String).flatMap(Double.init),
                  (0...1).contains(confidence) else {
                return nil
            }
            return index
        })
        guard measuredIndexes.count == sections.count,
              labeledIndexes == measuredIndexes else {
            throw GateBlocked(
                "Can't approve \"analysis\": section labels must cover every measured "
                    + "section index exactly once with a non-empty label and confidence."
            )
        }
        let overall = interpretation?["overall_character"] as? String ?? ""
        guard !overall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GateBlocked(
                "Can't approve \"analysis\": overall_character is missing from the "
                    + "persisted interpretation."
            )
        }
        let timeline = try measuredSections(dataRoot: dataRoot, phase: "analysis")
        let tolerance = 0.5
        guard let first = timeline.first,
              let last = timeline.last,
              first.start <= tolerance,
              abs(last.end - duration) <= tolerance else {
            throw GateBlocked(
                "Can't approve \"analysis\": interpreted sections don't cover the "
                    + "complete measured song."
            )
        }
        for pair in zip(timeline, timeline.dropFirst()) {
            guard abs(pair.0.end - pair.1.start) <= tolerance else {
                throw GateBlocked(
                    "Can't approve \"analysis\": interpreted sections contain a gap "
                        + "or overlap around \(pair.0.end)s."
                )
            }
        }
    }

    // MARK: - Per-phase acceptance harness
    // Typed writers create the artifacts; these gates independently revalidate their persisted truth.

    /// `brief`: a schema-valid brief.yaml (decode enforces the whole Brief contract, incl. budget and
    /// visual-medium-notes rules) plus a concrete target platform.
    static func requireRealBrief(dataRoot: URL) throws {
        let brief: Brief
        do {
            brief = try YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
        } catch {
            throw GateBlocked("Can't approve \"brief\": no valid brief.yaml yet (\(error)). Write the brief "
                + "with its required fields before approving.")
        }
        guard !brief.targetPlatform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GateBlocked("Can't approve \"brief\": target_platform is empty — set a concrete platform.")
        }
        try requireProjectIdentity(brief.project, phase: "brief", dataRoot: dataRoot)
        let meta = try projectMeta(dataRoot: dataRoot, phase: "brief")
        guard brief.projectMode == meta.mode.rawValue,
              abs(brief.budgetEur - meta.budgetEur) < 0.000_001 else {
            throw GateBlocked(
                "Can't approve \"brief\": its mode or budget is not synchronized "
                    + "with project.yaml."
            )
        }
    }

    /// `shotlist`: a schema-valid, non-empty shotlist whose shots COVER the measured song. For
    /// beat/section modes the shots must reach the song's end and the shotlist's song duration must
    /// match the measured analysis — so a shot list can't be authored against a hallucinated length.
    static func requireRealShotlist(dataRoot: URL) throws {
        guard let shotlist = try? loadShotlist(dataRoot: dataRoot), !shotlist.shots.isEmpty else {
            throw GateBlocked("Can't approve \"shotlist\": no valid, non-empty shot list yet (it must decode "
                + "against the engine schema).")
        }
        try requireProjectIdentity(shotlist.project, phase: "shotlist", dataRoot: dataRoot)
        guard let brief = try? YAMLArtifactStore(dataRoot: dataRoot).load(
            Brief.self,
            at: PipelineLayout.briefFile
        ) else {
            throw GateBlocked("Can't approve \"shotlist\": the approved brief is missing or invalid.")
        }
        guard shotlist.mode.rawValue == brief.projectMode,
              abs(shotlist.budgetEur - brief.budgetEur) < 0.000_001 else {
            throw GateBlocked(
                "Can't approve \"shotlist\": its mode or budget doesn't match the brief."
            )
        }
        let importedPlans = shotlist.shots.filter {
            $0.sourceMode == .imported && $0.productionPlan != nil
        }
        guard importedPlans.isEmpty else {
            throw GateBlocked(
                "Can't approve \"shotlist\": imported shots must omit production_plan "
                    + "(e.g. \(importedPlans.prefix(3).map(\.id).joined(separator: ", ")))."
            )
        }
        if Shotlist.requiresProductionPlan(forGenerator: shotlist.generator) {
            let missingPlans = shotlist.shots.filter {
                ProductionDiscipline.requiresProductionPlan($0)
                    && $0.productionPlan == nil
            }
            guard missingPlans.isEmpty else {
                throw GateBlocked(
                    "Can't approve \"shotlist\": canonical agent-written generated and "
                        + "AI-enhanced shots require production_plan (e.g. "
                        + "\(missingPlans.prefix(3).map(\.id).joined(separator: ", ")))."
                )
            }
        }
        let analysis = try analysisObject(dataRoot: dataRoot, phase: "shotlist")
        let measuredBPM = number(analysis["bpm"]) ?? 0
        let measuredMultiplier = number(analysis["tempo_multiplier"]) ?? 0
        guard abs(shotlist.song.bpm - measuredBPM) < 0.000_001,
              abs(shotlist.song.tempoMultiplier - measuredMultiplier) < 0.000_001 else {
            throw GateBlocked(
                "Can't approve \"shotlist\": its BPM or tempo multiplier doesn't match "
                    + "the approved measured analysis."
            )
        }
        var songPaths = [shotlist.song.audioPath, shotlist.song.analysisPath]
        if let lyrics = shotlist.song.lyricsPath { songPaths.append(lyrics) }
        try requireProjectFiles(
            songPaths,
            phase: "shotlist",
            label: "song artifact",
            dataRoot: dataRoot
        )
        let currentSong: URL
        do {
            currentSong = try MusicvideoAnalysisRunner.locateSong(
                dataRoot: dataRoot
            )
        } catch {
            throw GateBlocked(
                "Can't approve \"shotlist\": the current track is missing or ambiguous."
            )
        }
        guard let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(
            dataRoot: dataRoot
        ),
        sameProjectPath(
            shotlist.song.audioPath,
            FrameInventory.relativePath(of: currentSong, to: dataRoot),
            dataRoot: dataRoot
        ),
        sameProjectPath(
            shotlist.song.analysisPath,
            FrameInventory.relativePath(of: analysisURL, to: dataRoot),
            dataRoot: dataRoot
        ) else {
            throw GateBlocked(
                "Can't approve \"shotlist\": its Song block doesn't point to the "
                    + "current track and measured analysis."
            )
        }
        let lyricsURL = dataRoot.appendingPathComponent("lyrics/lyrics.txt")
        let hasLyrics = FileManager.default.fileExists(atPath: lyricsURL.path)
        guard hasLyrics == (shotlist.song.lyricsPath != nil),
              !hasLyrics || sameProjectPath(
                  shotlist.song.lyricsPath ?? "",
                  "lyrics/lyrics.txt",
                  dataRoot: dataRoot
              ) else {
            throw GateBlocked(
                "Can't approve \"shotlist\": its Song block isn't synchronized "
                + "with the current optional lyrics."
            )
        }
        let explicitReferences = shotlist.shots.flatMap(\.referenceImageRefs)
        try requireProjectImages(
            explicitReferences,
            phase: "shotlist",
            label: "explicit image reference",
            dataRoot: dataRoot
        )
        let enhancedSources = shotlist.shots.compactMap {
            $0.sourceMode == .aiEnhanced ? $0.sourcePath : nil
        }
        try requireProjectFiles(
            enhancedSources,
            phase: "shotlist",
            label: "AI-enhanced source video",
            dataRoot: dataRoot
        )
        guard enhancedSources.allSatisfy({
            guard let url = existingProjectFile($0, dataRoot: dataRoot) else {
                return false
            }
            return ProjectMediaExtensions.videos.contains(
                url.pathExtension.lowercased()
            )
        }) else {
            throw GateBlocked(
                "Can't approve \"shotlist\": every AI-enhanced source_path must "
                    + "point to a project-local video file."
            )
        }
        let invalidSourceModes = shotlist.shots.filter { shot in
            switch shot.sourceMode {
            case .generated:
                return shot.sourcePath != nil
            case .imported:
                return shot.keyframeStrategy != .none
                    || shot.chainWithPreviousEnd
            case .aiEnhanced:
                return normalized(shot.sourcePath ?? "").isEmpty
                    || shot.keyframeStrategy != .none
                    || shot.chainWithPreviousEnd
                    || shot.seedanceInputMode != .keyframe
                    || !shot.referenceImageRefs.isEmpty
            }
        }
        guard invalidSourceModes.isEmpty else {
            throw GateBlocked(
                "Can't approve \"shotlist\": generated shots cannot carry a source_path; "
                    + "imported and AI-enhanced shots cannot request generated keyframes or "
                    + "chaining; every AI-enhanced shot needs one project-local source_path "
                    + "and no undeclared provider references (e.g. "
                    + invalidSourceModes.prefix(3).map(\.id)
                        .joined(separator: ", ")
                    + ")."
            )
        }
        let invalidChains = shotlist.shots.filter {
            $0.chainWithPreviousEnd
                && (
                    $0.sourceMode != .generated
                        || $0.keyframeStrategy != .none
                        || $0.seedanceInputMode != .keyframe
                        || !$0.referenceImageRefs.isEmpty
                        || ChainContinuity.chainPredecessor(
                            shotlist,
                            shotId: $0.id
                        ) == nil
                )
        }
        guard invalidChains.isEmpty else {
            throw GateBlocked(
                "Can't approve \"shotlist\": chained shots must use their predecessor "
                    + "as the sole start-frame condition: source_mode=generated, "
                    + "keyframe_strategy=none, seedance_input_mode=keyframe, no "
                    + "reference images, and an earlier rendered predecessor (e.g. "
                    + invalidChains.prefix(3).map(\.id).joined(separator: ", ")
                    + ")."
            )
        }
        guard let storyboard = try? StoryboardStore.load(
            dataRoot: dataRoot,
            version: .current
        ) else {
            throw GateBlocked(
                "Can't approve \"shotlist\": the approved storyboard is missing or invalid."
            )
        }
        let invalidReferenceMode = shotlist.shots.filter {
            $0.seedanceInputMode == .reference
                && (
                    $0.keyframeStrategy != .none
                        || $0.chainWithPreviousEnd
                )
        }
        guard invalidReferenceMode.isEmpty else {
            throw GateBlocked(
                "Can't approve \"shotlist\": reference-mode shot(s) must use "
                    + "keyframe_strategy=none and cannot chain from a previous "
                    + "end frame because that provider mode ignores keyframes (e.g. "
                    + invalidReferenceMode.prefix(3).map(\.id)
                        .joined(separator: ", ")
                    + ")."
            )
        }
        guard let measured = BeatAssembly.loadBeatGrid(dataRoot: dataRoot) else {
            throw GateBlocked("Can't approve \"shotlist\": the measured analysis is missing — approve "
                + "\"analysis\" first so shot timing can be checked against the real song.")
        }
        let tol = 0.5
        guard abs(shotlist.song.durationS - measured.durationS) <= tol else {
            throw GateBlocked("Can't approve \"shotlist\": its song duration (\(shotlist.song.durationS)s) "
                + "doesn't match the measured analysis (\(measured.durationS)s) — it was built against the "
                + "wrong length. Rebuild it from the measured song.")
        }
        let ordered = shotlist.shots.sorted {
            $0.timeStart == $1.timeStart
                ? $0.timeEnd < $1.timeEnd
                : $0.timeStart < $1.timeStart
        }
        guard let first = ordered.first,
              first.timeStart <= tol else {
            throw GateBlocked(
                "Can't approve \"shotlist\": the timeline is uncovered at the beginning."
            )
        }
        var coveredUntil = first.timeEnd
        for shot in ordered.dropFirst() {
            guard shot.timeStart <= coveredUntil + tol else {
                throw GateBlocked(
                    "Can't approve \"shotlist\": the timeline has an uncovered gap "
                        + "between \(coveredUntil)s and \(shot.timeStart)s."
                )
            }
            coveredUntil = max(coveredUntil, shot.timeEnd)
        }
        guard ordered.allSatisfy({
            $0.timeStart <= measured.durationS + tol
                && $0.timeEnd <= measured.durationS + tol
        }) else {
            throw GateBlocked(
                "Can't approve \"shotlist\": a shot extends beyond the measured song."
            )
        }
        guard coveredUntil >= measured.durationS - tol else {
            throw GateBlocked("Can't approve \"shotlist\": shots stop at \(coveredUntil)s but the song runs "
                + "\(measured.durationS)s — the tail is uncovered. Cover the whole track.")
        }
        let storyboardSections = Set(storyboard.sections.map(\.id))
        let shotSections = Set(shotlist.shots.compactMap(\.section))
        let sectionAssignmentsValid = shotlist.shots.allSatisfy { shot in
            guard let sectionID = shot.section else {
                return !["beat", "section"].contains(
                    shotlist.mode.rawValue
                )
            }
            guard let section = storyboard.sections.first(where: {
                $0.id == sectionID
            }) else { return false }
            return shot.timeStart >= section.timeStart - tol
                && shot.timeEnd <= section.timeEnd + tol
        }
        let requiresEverySection = ["beat", "section"].contains(
            shotlist.mode.rawValue
        )
        guard sectionAssignmentsValid,
              !requiresEverySection
                || shotSections == storyboardSections else {
            throw GateBlocked(
                "Can't approve \"shotlist\": its section assignments don't cover "
                    + "the approved storyboard within its measured intervals."
            )
        }
    }

    static func requireCurrentSanity(dataRoot: URL) throws {
        let artifact: SanityArtifact
        do {
            artifact = try SanityArtifactStore.load(dataRoot: dataRoot)
        } catch {
            throw GateBlocked(
                "Can't approve \"sanity\": no persisted sanity report exists. Run run_sanity first."
            )
        }
        try requireProjectIdentity(artifact.project, phase: "sanity", dataRoot: dataRoot)
        let current = SanityArtifactStore.inputFingerprint(dataRoot: dataRoot)
        guard artifact.inputFingerprint == current else {
            throw GateBlocked(
                "Can't approve \"sanity\": its report is stale because an audited artifact changed. "
                    + "Run run_sanity again."
            )
        }
        guard artifact.errors.isEmpty else {
            throw GateBlocked(
                "Can't approve \"sanity\": \(artifact.errors.count) blocking error(s) remain. "
                    + "Fix them and run run_sanity again."
            )
        }
    }

    /// `bible`: a schema-valid bible (decode enforces global-unique ids + the per-entity anchor rule),
    /// at least one character/ensemble/location, and every reference image / sheet it lists must
    /// ACTUALLY exist on disk — the agent can't record art it never generated.
    static func requireRealBible(dataRoot: URL) throws {
        guard let bible = try? loadBible(dataRoot: dataRoot) else {
            throw GateBlocked("Can't approve \"bible\": no valid bible/bible.yaml yet (schema-valid, every "
                + "entity with at least one reference image or sheet).")
        }
        guard !bible.characters.isEmpty || !bible.ensembles.isEmpty || !bible.locations.isEmpty else {
            throw GateBlocked("Can't approve \"bible\": it defines no characters, ensembles, or locations.")
        }
        try requireProjectIdentity(bible.project, phase: "bible", dataRoot: dataRoot)
        guard let brief = try? YAMLArtifactStore(dataRoot: dataRoot).load(
            Brief.self,
            at: PipelineLayout.briefFile
        ),
        let design = try? YAMLArtifactStore(dataRoot: dataRoot).load(
            ProductionDesign.self,
            at: "production_design/production_design.yaml"
        ) else {
            throw GateBlocked(
                "Can't approve \"bible\": the approved Brief or Production Design is missing."
            )
        }
        if brief.visualMedium != .liveActionRealistic {
            guard normalized(bible.look.style)
                == normalized(design.visualMediumNotes),
                  !normalized(bible.look.style).isEmpty else {
                throw GateBlocked(
                    "Can't approve \"bible\": look.style must carry the approved "
                        + "Production Design style verbatim."
                )
            }
        }
        guard sameProjectPathOrBothEmpty(
            bible.look.lightingAnchor,
            design.lightingAnchor,
            dataRoot: dataRoot
        ) else {
            throw GateBlocked(
                "Can't approve \"bible\": look.lighting_anchor must match the "
                    + "approved Production Design lighting anchor."
            )
        }
        var claimed: [String] = []
        for c in bible.characters { claimed += c.referenceImages + Array(c.sheets.values) }
        for e in bible.ensembles { claimed += e.referenceImages + Array(e.sheets.values) }
        for p in bible.props { claimed += p.referenceImages + Array(p.sheets.values) }
        for l in bible.locations {
            claimed += l.referenceImages + Array(l.sheets.values)
            claimed += l.zones.flatMap(\.bibleAssets)
            if !l.floorplan.isEmpty { claimed.append(l.floorplan) }
            if !l.scene3d.panorama.isEmpty { claimed.append(l.scene3d.panorama) }
        }
        if !bible.look.lightingAnchor.isEmpty { claimed.append(bible.look.lightingAnchor) }
        try requireProjectImages(
            claimed,
            phase: "bible",
            label: "reference",
            dataRoot: dataRoot
        )
        var generated = bible.characters.flatMap {
            Array($0.sheets.values)
        }
        generated += bible.ensembles.flatMap {
            Array($0.sheets.values)
        }
        generated += bible.props.flatMap {
            Array($0.sheets.values)
        }
        generated += bible.locations.flatMap {
            Array($0.sheets.values)
                + ($0.scene3d.panorama.isEmpty
                    ? []
                    : [$0.scene3d.panorama])
        }
        try requireGeneratedProjectFiles(
            generated,
            scope: "bible",
            phase: "bible",
            dataRoot: dataRoot
        )

        guard let storyboard = try? StoryboardStore.load(dataRoot: dataRoot, version: .current) else {
            throw GateBlocked("Can't approve \"bible\": the approved storyboard is missing or invalid.")
        }
        let locationByID = Dictionary(uniqueKeysWithValues: bible.locations.map { ($0.id, $0) })
        for (locationID, views) in storyboard.locationViewDemand() {
            guard let location = locationByID[locationID] else {
                throw GateBlocked(
                    "Can't approve \"bible\": storyboard location \"\(locationID)\" is missing."
                )
            }
            let missingViews = views.filter { location.sheets[$0] == nil }
            guard missingViews.isEmpty else {
                throw GateBlocked(
                    "Can't approve \"bible\": location \"\(locationID)\" lacks storyboard-required "
                        + "view(s): \(missingViews.sorted().joined(separator: ", "))."
                )
            }
        }
        let characterByID = Dictionary(uniqueKeysWithValues: bible.characters.map { ($0.id, $0) })
        let propByID = Dictionary(uniqueKeysWithValues: bible.props.map { ($0.id, $0) })
        for step in storyboard.allSteps() {
            for (characterID, view) in step.characterViewRequest {
                guard let character = characterByID[characterID],
                      character.sheets[view] != nil else {
                    throw GateBlocked(
                        "Can't approve \"bible\": step \(step.id) requires character "
                            + "\"\(characterID)\" view \"\(view)\", but that sheet is missing."
                    )
                }
            }
            for propID in step.propRequest {
                guard let prop = propByID[propID], prop.hasAnchor() else {
                    throw GateBlocked(
                        "Can't approve \"bible\": step \(step.id) requires anchored prop "
                            + "\"\(propID)\", but it is missing."
                    )
                }
            }
        }
    }

    /// `treatment`: schema-valid frontmatter (decode enforces version/origin/…), a real one-line
    /// summary, and a non-empty prose body.
    static func requireRealTreatment(dataRoot: URL) throws {
        let versions = TreatmentStore.versions(dataRoot: dataRoot)
        guard let latest = versions.last else {
            throw GateBlocked("Can't approve \"treatment\": no valid treatment yet.")
        }
        let treatment: Treatment
        do {
            treatment = try TreatmentStore.load(
                dataRoot: dataRoot,
                version: latest
            )
        }
        catch { throw GateBlocked("Can't approve \"treatment\": no valid treatment yet (\(error)).") }
        try currentVersionMatches(
            current: PipelineLayout.treatmentCurrentFile,
            versioned: PipelineLayout.treatmentVersionFile(latest),
            phase: "treatment",
            dataRoot: dataRoot
        )
        guard treatment.meta.version == latest else {
            throw GateBlocked(
                "Can't approve \"treatment\": its version metadata doesn't match v\(latest).md."
            )
        }
        guard !treatment.meta.summaryOneline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GateBlocked("Can't approve \"treatment\": its one-line summary is empty.")
        }
        guard !treatment.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GateBlocked("Can't approve \"treatment\": the treatment body is empty — write it.")
        }
        try requireProjectIdentity(
            treatment.meta.project,
            phase: "treatment",
            dataRoot: dataRoot
        )
        guard let brief = try? YAMLArtifactStore(dataRoot: dataRoot).load(
            Brief.self,
            at: PipelineLayout.briefFile
        ) else {
            throw GateBlocked(
                "Can't approve \"treatment\": the approved brief is missing."
            )
        }
        let style = normalized(brief.visualMediumNotes)
        if !style.isEmpty {
            guard treatment.bodyMarkdown.localizedCaseInsensitiveContains(
                style
            ) else {
                throw GateBlocked(
                    "Can't approve \"treatment\": the body doesn't carry the "
                        + "approved visual_medium_notes verbatim."
                )
            }
        }
    }

    /// `storyboard`: schema-valid, real sections each with steps, matching the complete measured song.
    static func requireRealStoryboard(dataRoot: URL) throws {
        guard let storyboard = try? StoryboardStore.load(dataRoot: dataRoot, version: .current),
              !storyboard.sections.isEmpty else {
            throw GateBlocked("Can't approve \"storyboard\": no valid, non-empty storyboard yet.")
        }
        guard storyboard.sections.allSatisfy({ !$0.steps.isEmpty }) else {
            throw GateBlocked("Can't approve \"storyboard\": a section has no steps — each needs at least one.")
        }
        guard !normalized(storyboard.meta.summaryOneline).isEmpty else {
            throw GateBlocked(
                "Can't approve \"storyboard\": its one-line summary is empty."
            )
        }
        let latestVersion = StoryboardStore.nextVersion(dataRoot: dataRoot) - 1
        guard latestVersion >= 1,
              storyboard.meta.version == latestVersion else {
            throw GateBlocked(
                "Can't approve \"storyboard\": current.yaml is not the newest version."
            )
        }
        try currentVersionMatches(
            current: PipelineLayout.storyboardCurrentFile,
            versioned: PipelineLayout.storyboardVersionFile(latestVersion),
            phase: "storyboard",
            dataRoot: dataRoot
        )
        try requireProjectIdentity(
            storyboard.meta.project,
            phase: "storyboard",
            dataRoot: dataRoot
        )
        let measured = try measuredSections(dataRoot: dataRoot, phase: "storyboard")
        guard storyboard.sections.count == measured.count else {
            throw GateBlocked(
                "Can't approve \"storyboard\": it has \(storyboard.sections.count) sections, "
                    + "but the approved analysis has \(measured.count)."
            )
        }
        let tolerance = 0.5
        var sectionIDs: Set<String> = []
        for (position, pair) in zip(storyboard.sections, measured).enumerated() {
            let section = pair.0
            let source = pair.1
            guard sectionIDs.insert(section.id).inserted else {
                throw GateBlocked(
                    "Can't approve \"storyboard\": duplicate section id \"\(section.id)\"."
                )
            }
            guard section.timeEnd > section.timeStart,
                  abs(section.timeStart - source.start) <= tolerance,
                  abs(section.timeEnd - source.end) <= tolerance else {
                throw GateBlocked(
                    "Can't approve \"storyboard\": section \(position + 1) doesn't match "
                        + "the measured interval \(source.start)–\(source.end)s."
                )
            }
            guard section.label.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(
                    source.label.trimmingCharacters(in: .whitespacesAndNewlines)
                ) == .orderedSame else {
                throw GateBlocked(
                    "Can't approve \"storyboard\": section \(section.id) doesn't carry "
                        + "the approved analysis label \"\(source.label)\"."
                )
            }
            guard section.steps.allSatisfy({
                $0.id.hasPrefix(section.id + ".")
            }) else {
                throw GateBlocked(
                    "Can't approve \"storyboard\": every step in \(section.id) must use "
                        + "that section id as its prefix."
                )
            }
            guard (4...12).contains(section.steps.count) else {
                throw GateBlocked(
                    "Can't approve \"storyboard\": section \(section.id) needs "
                        + "4–12 ordered steps, not \(section.steps.count)."
                )
            }
            let expectedStepIDs = (1...section.steps.count).map {
                "\(section.id).\(String(format: "%02d", $0))"
            }
            guard section.steps.map(\.id) == expectedStepIDs else {
                throw GateBlocked(
                    "Can't approve \"storyboard\": section \(section.id) step ids "
                        + "must be gapless and ordered."
                )
            }
            let unanchoredSteps = section.steps.filter(
                ProductionDiscipline.hasUnanchoredCharacterBlocking
            )
            guard unanchoredSteps.isEmpty else {
                throw GateBlocked(
                    "Can't approve \"storyboard\": generated character blocking must "
                        + "name a non-directional set_anchor and a non-empty "
                        + "relation_to_set (e.g. "
                        + "\(unanchoredSteps.prefix(3).map(\.id).joined(separator: ", ")))."
                )
            }
            guard ["low", "mid", "high", "drop"].contains(section.energy),
                  ["aufbau", "refrain", "kontrast", "aufloesung"]
                    .contains(section.function),
                  section.steps.allSatisfy({
                      !$0.framing.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                          && !$0.settingHint.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          ).isEmpty
                          && !$0.locationViewRequest.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          ).isEmpty
                          && !$0.cameraSetup.isEmpty
                  }) else {
                throw GateBlocked(
                    "Can't approve \"storyboard\": section \(section.id) has "
                        + "missing energy/function or incomplete step composition."
                )
            }
        }
    }

    /// `production_design`: schema-valid, names the same visual medium as the brief, and every claimed
    /// reference exists. Content judgement still belongs to the user; structural truth belongs here.
    static func requireRealProductionDesign(dataRoot: URL) throws {
        let design: ProductionDesign
        do {
            design = try YAMLArtifactStore(dataRoot: dataRoot).load(
                ProductionDesign.self,
                at: "production_design/production_design.yaml"
            )
        } catch {
            throw GateBlocked("Can't approve \"production_design\": no valid production_design.yaml yet.")
        }
        try requireProjectIdentity(
            design.project,
            phase: "production_design",
            dataRoot: dataRoot
        )
        let brief: Brief
        do {
            brief = try YAMLArtifactStore(dataRoot: dataRoot).load(
                Brief.self,
                at: PipelineLayout.briefFile
            )
        } catch {
            throw GateBlocked(
                "Can't approve \"production_design\": the approved brief is missing or invalid."
            )
        }
        guard design.visualMedium == brief.visualMedium else {
            throw GateBlocked("Can't approve \"production_design\": visual_medium (\(design.visualMedium.rawValue)) "
                + "doesn't match the brief (\(brief.visualMedium.rawValue)).")
        }
        guard normalized(design.visualMediumNotes)
            == normalized(brief.visualMediumNotes) else {
            throw GateBlocked(
                "Can't approve \"production_design\": visual_medium_notes must "
                    + "match the synchronized Brief exactly."
            )
        }
        if !design.colorScript.isEmpty {
            let expected = Set(
                try measuredSections(
                    dataRoot: dataRoot,
                    phase: "production_design"
                ).map(\.label)
            )
            guard Set(design.colorScript.keys) == expected,
                  design.colorScript.values.allSatisfy({
                      !normalized($0).isEmpty
                  }) else {
                throw GateBlocked(
                    "Can't approve \"production_design\": a non-empty color script "
                        + "must cover every approved analysis section exactly once."
                )
            }
        }
        let paths = design.refs.map(\.path)
            + (design.lightingAnchor.isEmpty ? [] : [design.lightingAnchor])
        let refPaths = design.refs.map(\.path)
        guard Set(refPaths).count == refPaths.count,
              refPaths.allSatisfy({
                  $0.hasPrefix("production_design/refs/")
              }),
              design.lightingAnchor.isEmpty
                || design.lightingAnchor
                    == "production_design/lighting_anchor.png" else {
            throw GateBlocked(
                "Can't approve \"production_design\": refs and lighting anchor "
                    + "must use their canonical Production Design paths without duplicates."
            )
        }
        try requireProjectImages(
            paths,
            phase: "production_design",
            label: "reference",
            dataRoot: dataRoot
        )
    }

    /// `frames`: every required role exists, came through the compiled prompt path, and has a
    /// schema-valid vision audit bound to the exact current file hash.
    static func requireRealFrames(dataRoot: URL) throws {
        guard let shotlist = try? loadShotlist(dataRoot: dataRoot) else {
            throw GateBlocked("Can't approve \"frames\": no shotlist to render keyframes for.")
        }
        let manifest: FramesManifest
        do {
            manifest = try loadFramesManifest(dataRoot: dataRoot)
        } catch {
            throw GateBlocked(
                "Can't approve \"frames\": frames/manifest.json is missing or invalid (\(error))."
            )
        }
        try requireProjectIdentity(manifest.project, phase: "frames", dataRoot: dataRoot)
        guard manifest.schema == framesSchemaVersion else {
            throw GateBlocked(
                "Can't approve \"frames\": unsupported manifest schema \"\(manifest.schema)\"."
            )
        }
        let shotIDs = manifest.shots.map(\.shotId)
        guard Set(shotIDs).count == shotIDs.count else {
            throw GateBlocked("Can't approve \"frames\": the manifest contains duplicate shot entries.")
        }
        let expectedShotIDs = Set(shotlist.shots.compactMap {
            $0.sourceMode == .generated && $0.keyframeStrategy != .none ? $0.id : nil
        })
        guard Set(shotIDs) == expectedShotIDs else {
            throw GateBlocked(
                "Can't approve \"frames\": the manifest doesn't match the current shot list."
            )
        }
        for shot in shotlist.shots where shot.sourceMode == .generated {
            let roles: [String]
            switch shot.keyframeStrategy {
            case .none: continue
            case .start: roles = ["start"]
            case .startEnd: roles = ["start", "end"]
            }
            guard let recorded = manifest.shot(shot.id),
                  recorded.keyframeStrategy == shot.keyframeStrategy.rawValue else {
                throw GateBlocked(
                    "Can't approve \"frames\": \(shot.id) has no manifest entry matching "
                        + "keyframe strategy \(shot.keyframeStrategy.rawValue)."
                )
            }
            let recordedRoles = recorded.frames.map(\.role)
            guard Set(recordedRoles).count == recordedRoles.count,
                  Set(recordedRoles) == Set(roles) else {
                throw GateBlocked(
                    "Can't approve \"frames\": \(shot.id)'s frame roles don't match "
                        + "keyframe strategy \(shot.keyframeStrategy.rawValue)."
                )
            }
            for role in roles {
                guard let frame = recorded.frames.first(where: { $0.role == role }) else {
                    throw GateBlocked(
                        "Can't approve \"frames\": \(shot.id)-\(role) is missing."
                    )
                }
                guard !frame.providerPrompt
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw GateBlocked(
                        "Can't approve \"frames\": \(shot.id)-\(role) has no compiled provider prompt."
                    )
                }
                guard promptContains(
                    frame.providerPrompt,
                    requirements: shot.stillProductionPromptRequirements
                ) else {
                    throw GateBlocked(
                        "Can't approve \"frames\": \(shot.id)-\(role)'s provider prompt "
                            + "doesn't contain its current production-plan directives."
                    )
                }
                guard ProductionPromptPolicy.stillPromptViolations(
                    frame.providerPrompt
                ).isEmpty else {
                    throw GateBlocked(
                        "Can't approve \"frames\": \(shot.id)-\(role)'s provider prompt "
                            + "contains camera motion."
                    )
                }
                guard !frame.runwayModel
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw GateBlocked(
                        "Can't approve \"frames\": \(shot.id)-\(role) has no "
                            + "recorded generation model."
                    )
                }
                guard let frameURL = existingProjectFile(frame.path, dataRoot: dataRoot) else {
                    throw GateBlocked(
                        "Can't approve \"frames\": \(shot.id)-\(role) isn't a real project image."
                    )
                }
                guard ProjectMediaExtensions.images.contains(
                    frameURL.pathExtension.lowercased()
                ) else {
                    throw GateBlocked(
                        "Can't approve \"frames\": \(shot.id)-\(role) isn't an image file."
                    )
                }
                let audit: FrameAudit
                do {
                    guard let loaded = try loadFrameAudit(
                        dataRoot: dataRoot,
                        shotId: shot.id,
                        role: role
                    ) else {
                        throw GateBlocked(
                            "Can't approve \"frames\": \(shot.id)-\(role) has no vision audit."
                        )
                    }
                    audit = loaded
                } catch let blocked as GateBlocked {
                    throw blocked
                } catch {
                    throw GateBlocked(
                        "Can't approve \"frames\": \(shot.id)-\(role) has an invalid vision audit "
                            + "(\(error))."
                    )
                }
                guard audit.shotId == shot.id,
                      audit.role == role,
                      Set(standardAuditCheckKeys).isSubset(of: Set(audit.checks.keys)),
                      let auditedURL = existingProjectFile(audit.renderPath, dataRoot: dataRoot),
                      auditedURL == frameURL,
                      sha256(frameURL) == audit.renderSha256 else {
                    throw GateBlocked(
                        "Can't approve \"frames\": \(shot.id)-\(role)'s audit is incomplete "
                            + "or stale for the current image."
                    )
                }
            }
        }
    }

    /// `render`: terminal gate — every provider-rendered shot is bound to the exact generated video.
    static func requireRealRender(dataRoot: URL) throws {
        guard let shotlist = try? loadShotlist(dataRoot: dataRoot) else {
            throw GateBlocked("Can't approve \"render\": no shotlist to render against.")
        }
        let required = shotlist.shots.filter { $0.sourceMode != .imported }.map(\.id)
        let requiredSet = Set(required)
        let manifest: RenderManifest
        do {
            manifest = try loadRenderManifest(dataRoot: dataRoot, phase: "final")
        } catch {
            throw GateBlocked(
                "Can't approve \"render\": the final render manifest is invalid (\(error))."
            )
        }
        try requireProjectIdentity(manifest.project, phase: "render", dataRoot: dataRoot)
        guard manifest.schema_ == renderManifestSchemaVersion,
              manifest.phase == "final" else {
            throw GateBlocked("Can't approve \"render\": the final render manifest has the wrong identity.")
        }
        let proof: RenderProofManifest
        do {
            proof = try loadRenderProofManifest(
                dataRoot: dataRoot,
                phase: "final"
            )
        } catch {
            throw GateBlocked(
                "Can't approve \"render\": the final render provenance is invalid (\(error))."
            )
        }
        guard proof.schema == renderProofSchemaVersion,
              proof.project == manifest.project,
              proof.phase == "final" else {
            throw GateBlocked(
                "Can't approve \"render\": the final render provenance has the wrong identity."
            )
        }
        guard Set(manifest.entries.keys) == requiredSet,
              Set(proof.entries.keys) == requiredSet else {
            throw GateBlocked(
                "Can't approve \"render\": the final manifest or provenance "
                    + "doesn't match the current provider-rendered shot set."
            )
        }
        let frames = try? loadFramesManifest(dataRoot: dataRoot)
        let missing = required.filter {
            let e = manifest.entries[$0]
            let p = proof.entries[$0]
            guard e?.status == .rendered,
                  e?.shotId == $0,
                  e?.phase == "final",
                  let cost = e?.costEur,
                  cost.isFinite,
                  cost >= 0,
                  let output = e?.output,
                  !output.isEmpty,
                  p?.shotId == $0,
                  p?.output == output,
                  let proofEntry = p,
                  let shot = shotlist.shots.first(where: {
                      $0.id == proofEntry.shotId
                  }),
                  let providerPrompt = p?.providerPrompt,
                  !providerPrompt.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  promptContains(
                    providerPrompt,
                    requirements: shot.videoProductionPromptRequirements
                  ),
                  ProductionPromptPolicy.videoPromptViolations(
                    providerPrompt,
                    expectedMovement: shot.productionPlan?.cameraMovement
                  ).isEmpty,
                  let generationModel = p?.generationModel,
                  !generationModel.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  let outputSha256 = p?.outputSha256,
                  renderConditioningMatches(
                    shot: shot,
                    proof: proofEntry,
                    shotlist: shotlist,
                    manifest: manifest,
                    frames: frames,
                    dataRoot: dataRoot
                  ) else {
                return true
            }
            guard let url = existingProjectFile(output, dataRoot: dataRoot) else {
                return true
            }
            return !ProjectMediaExtensions.videos.contains(
                url.pathExtension.lowercased()
            ) || sha256(url) != outputSha256
        }
        guard missing.isEmpty else {
            throw GateBlocked(
                "Can't approve \"render\": \(missing.count) shot(s) lack a current "
                    + "provider-generated final video with compiled-prompt provenance "
                    + "(e.g. \(missing.prefix(3).joined(separator: ", ")))."
            )
        }
    }

    /// `cover` (optional): if approved, at least one format's cover was really produced — its clean image
    /// exists on disk.
    static func requireRealCover(dataRoot: URL) throws {
        let produced = CoverFormatKey.allCases.contains { fmt in
            guard let manifest = try? Cover.load(projectDir: dataRoot, format: fmt.rawValue),
                  let clean = manifest.clean else { return false }
            let p = clean.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return false }
            return FileManager.default.fileExists(atPath: p)
                || FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(p).path)
                || FileManager.default.fileExists(atPath: FrameInventory.projectHome(of: dataRoot).appendingPathComponent(p).path)
        }
        guard produced else {
            throw GateBlocked("Can't approve \"cover\": no cover has a real clean image on disk — produce a "
                + "cover first, or leave the gate unset to skip it.")
        }
    }
}
