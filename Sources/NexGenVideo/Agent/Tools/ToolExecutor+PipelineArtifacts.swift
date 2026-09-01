import Foundation
import NexGenEngine

extension ToolExecutor {
    func writeAnalysisInterpretationTool(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let declaration = try mutationPackDeclaration(
            editor,
            dataRoot: root
        )
        let resolvedPack: String?
        do {
            resolvedPack = try ProjectPackGate.requireLiveMutation(
                projectURL: FrameInventory.projectHome(of: root),
                declaredPack: declaration.packName,
                declaredBinding: declaration.binding
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let registry = PackCatalog.registry(activePack: resolvedPack)
        do {
            try GateGuard.requireWiredPack(
                declared: editor.declaredPluginName,
                resolved: resolvedPack,
                registry: registry
            )
        } catch let blocked as GateBlocked {
            throw ToolError(blocked.message)
        }
        let artifactRequirement: EngineRegistry.GateRequirement?
        if resolvedPack != nil {
            guard let requirement = registry.artifactWriteRequirements["analysis"] else {
                throw ToolError(
                    "The active format pack has no analysis artifact-write contract. Reopen the project."
                )
            }
            artifactRequirement = requirement
        } else {
            artifactRequirement = nil
        }
        let measured = try currentMeasuredAnalysis(dataRoot: root)
        do {
            try artifactRequirement?(root)
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let analysisURL = measured.url
        var analysis = measured.object
        guard (analysis["beats"] as? [Any])?.isEmpty == false,
              (analysis["downbeats"] as? [Any])?.isEmpty == false,
              var sections = analysis["sections"] as? [[String: Any]],
              !sections.isEmpty else {
            throw ToolError(
                "The analysis has no measured beat/downbeat/section grid. "
                    + "Run run_phase(\"analysis\") successfully before interpreting it."
            )
        }

        guard let multiplier = args.double("tempo_multiplier") else {
            throw ToolError("Missing required argument: tempo_multiplier")
        }
        let allowedMultipliers = [0.5, 1.0, 2.0]
        guard allowedMultipliers.contains(where: {
            abs($0 - multiplier) < 0.000_001
        }) else {
            throw ToolError(
                "tempo_multiplier must be exactly 0.5, 1, or 2."
            )
        }

        let rawLabels = args["section_labels"] as? [[String: Any]] ?? []
        guard rawLabels.count == sections.count else {
            throw ToolError(
                "section_labels must contain exactly one entry for every measured section "
                    + "(\(sections.count) expected, \(rawLabels.count) received)."
            )
        }
        var measuredByIndex: [Int: Int] = [:]
        for position in sections.indices {
            guard let index = (sections[position]["index"] as? NSNumber)?.intValue else {
                throw ToolError(
                    "Measured section \(position) has no integer index; re-run analysis."
                )
            }
            guard measuredByIndex[index] == nil else {
                throw ToolError(
                    "Measured analysis contains duplicate section index \(index); re-run analysis."
                )
            }
            measuredByIndex[index] = position
        }

        var labels: [[String: String]] = []
        var seen: Set<Int> = []
        for (position, raw) in rawLabels.enumerated() {
            guard let index = (raw["index"] as? NSNumber)?.intValue,
                  let sectionPosition = measuredByIndex[index] else {
                throw ToolError(
                    "section_labels[\(position)].index does not name a measured section."
                )
            }
            guard seen.insert(index).inserted else {
                throw ToolError("section_labels contains duplicate index \(index).")
            }
            let label = try raw.requireString("label")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else {
                throw ToolError("section_labels[\(position)].label is empty.")
            }
            guard let confidence = raw.double("confidence") else {
                throw ToolError(
                    "section_labels[\(position)].confidence is missing."
                )
            }
            guard (0...1).contains(confidence) else {
                throw ToolError(
                    "section_labels[\(position)].confidence must be between 0 and 1."
                )
            }
            let note = raw.string("note") ?? ""
            labels.append([
                "index": String(index),
                "label": label,
                "confidence": String(format: "%.3f", confidence),
                "note": note,
            ])
            sections[sectionPosition]["label"] = label
        }
        guard seen == Set(measuredByIndex.keys) else {
            throw ToolError(
                "section_labels must cover every measured section index exactly once."
            )
        }

        let overall = try args.requireString("overall_character")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overall.isEmpty else {
            throw ToolError("overall_character is empty.")
        }
        let existingInterpretation = analysis["interpretation"] as? [String: Any]
        let detectorAnomalies = existingInterpretation?["anomalies"] as? [[String: Any]] ?? []
        let submittedAnomalies = args["anomalies"] as? [[String: Any]] ?? []
        var anomalies: [[String: String]] = []
        var anomalyKeys: Set<String> = []
        for raw in detectorAnomalies + submittedAnomalies {
            let kind = (raw["kind"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (raw["detail"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kind.isEmpty, !detail.isEmpty else {
                throw ToolError("Every anomaly needs non-empty kind and detail.")
            }
            var anomaly = ["kind": kind, "detail": detail]
            if let time = (raw["time"] as? NSNumber)?.doubleValue {
                anomaly["time"] = String(format: "%.3f", time)
            } else if let time = raw["time"] as? String, !time.isEmpty {
                anomaly["time"] = time
            }
            let key = [
                anomaly["kind"] ?? "",
                anomaly["time"] ?? "",
                anomaly["detail"] ?? "",
            ].joined(separator: "\u{1f}")
            if anomalyKeys.insert(key).inserted {
                anomalies.append(anomaly)
            }
        }

        analysis["tempo_multiplier"] = multiplier
        analysis["sections"] = sections
        analysis["interpretation"] = [
            "section_labels": labels,
            "anomalies": anomalies,
            "overall_character": overall,
        ]
        do {
            var output = try JSONSerialization.data(
                withJSONObject: analysis,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            output.append(0x0A)
            try output.write(to: analysisURL, options: .atomic)
        } catch {
            throw ToolError(
                "Couldn't persist the analysis interpretation: \(error)"
            )
        }
        let bpm = (analysis["bpm"] as? NSNumber)?.doubleValue ?? 0
        return try jsonResult([
            "written": true,
            "path": relativePath(analysisURL, dataRoot: root),
            "tempo_multiplier": multiplier,
            "perceived_bpm": bpm * multiplier,
            "section_labels": labels,
            "anomalies": anomalies,
        ])
    }

    func writeProductionDesignTool(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        var payload = args
        payload.removeValue(forKey: "project_dir")
        payload["schema"] = productionDesignSchemaVersion
        payload["project"] = projectName(dataRoot: root)
        payload["generated"] = currentTimestamp()
        payload["generator"] = "production-design-agent@write_production_design"
        payload["color_script"] = try keyedStrings(
            payload["color_script"],
            key: "section",
            value: "description",
            path: "write_production_design.color_script"
        )

        let design: ProductionDesign = try decodeArtifact(
            payload,
            as: ProductionDesign.self,
            label: "production design"
        )
        for reference in design.refs {
            try requireProjectImage(
                reference.path,
                dataRoot: root,
                field: "refs.path"
            )
        }
        if !design.lightingAnchor.isEmpty {
            try requireProjectImage(
                design.lightingAnchor,
                dataRoot: root,
                field: "lighting_anchor"
            )
        }

        let relative = "production_design/production_design.yaml"
        try archiveExisting(relative, dataRoot: root)
        do {
            try YAMLArtifactStore(dataRoot: root).save(design, to: relative)
        } catch {
            throw ToolError("Couldn't write production design: \(error)")
        }
        return try jsonResult([
            "written": true,
            "path": relative,
            "refs": design.refs.count,
            "color_sections": design.colorScript.count,
            "lighting_anchor": !design.lightingAnchor.isEmpty,
        ])
    }

    func writeTreatmentTool(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let originRaw = try args.requireString("origin")
        guard let origin = TreatmentOrigin(rawValue: originRaw) else {
            throw ToolError("Unknown treatment origin '\(originRaw)'.")
        }
        let version = TreatmentStore.nextVersion(dataRoot: root)
        let meta: TreatmentMeta
        do {
            meta = try TreatmentMeta(
                project: projectName(dataRoot: root),
                version: version,
                generated: currentTimestamp(),
                origin: origin,
                generator: "treatment-agent@write_treatment",
                summaryOneline: try args.requireString("summary_oneline"),
                title: args.string("title"),
                notes: args.string("notes")
            )
        } catch {
            throw ToolError("Treatment rejected: \(error)")
        }
        let body = try args.requireString("body_markdown")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("Treatment rejected: body_markdown is empty.")
        }
        let treatment = Treatment(meta: meta, bodyMarkdown: body)
        let url: URL
        do {
            url = try TreatmentStore.save(treatment, to: root)
        } catch {
            throw ToolError("Couldn't write treatment: \(error)")
        }
        return try jsonResult([
            "written": true,
            "version": version,
            "path": relativePath(url, dataRoot: root),
            "current": PipelineLayout.treatmentCurrentFile,
        ])
    }

    func writeStoryboardTool(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        var payload = args
        payload.removeValue(forKey: "project_dir")
        payload["schema"] = storyboardSchemaVersion
        var meta: [String: Any] = [
            "project": projectName(dataRoot: root),
            "version": StoryboardStore.nextVersion(dataRoot: root),
            "generated": currentTimestamp(),
            "origin": args["origin"]!,
            "generator": "storyboard-agent@write_storyboard",
            "summary_oneline": args["summary_oneline"]!,
        ]
        if let notes = args.string("notes") {
            meta["notes"] = notes
        }
        payload["meta"] = meta
        payload.removeValue(forKey: "origin")
        payload.removeValue(forKey: "summary_oneline")
        payload.removeValue(forKey: "notes")

        var sections = payload["sections"] as? [[String: Any]] ?? []
        for sectionIndex in sections.indices {
            var steps = sections[sectionIndex]["steps"] as? [[String: Any]] ?? []
            for stepIndex in steps.indices {
                steps[stepIndex]["character_view_request"] = try keyedStrings(
                    steps[stepIndex]["character_view_request"],
                    key: "character",
                    value: "view",
                    path: "write_storyboard.sections[\(sectionIndex)].steps[\(stepIndex)].character_view_request"
                )
            }
            sections[sectionIndex]["steps"] = steps
        }
        payload["sections"] = sections

        let storyboard: Storyboard = try decodeArtifact(
            payload,
            as: Storyboard.self,
            label: "storyboard"
        )
        let unanchoredSteps = storyboard.allSteps().filter(
            ProductionDiscipline.hasUnanchoredCharacterBlocking
        )
        guard unanchoredSteps.isEmpty else {
            throw ToolError(
                "Storyboard rejected: generated character blocking must name a concrete "
                    + "set_anchor from that step's prop_request or visible_zones and a non-empty "
                    + "relation_to_set (e.g. "
                    + "\(unanchoredSteps.prefix(3).map(\.id).joined(separator: ", ")))."
            )
        }
        let url: URL
        do {
            url = try StoryboardStore.save(storyboard, to: root)
        } catch {
            throw ToolError("Couldn't write storyboard: \(error)")
        }
        return try jsonResult([
            "written": true,
            "version": storyboard.meta.version,
            "path": relativePath(url, dataRoot: root),
            "current": PipelineLayout.storyboardCurrentFile,
            "sections": storyboard.sections.count,
            "steps": storyboard.allSteps().count,
        ])
    }

    func writeBibleTool(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        var payload = args
        payload.removeValue(forKey: "project_dir")
        payload["schema"] = bibleSchemaVersion
        payload["project"] = projectName(dataRoot: root)
        payload["generated"] = currentTimestamp()
        payload["generator"] = "bible-agent@write_bible"

        for collection in ["characters", "ensembles", "props", "locations"] {
            var entities = payload[collection] as? [[String: Any]] ?? []
            for index in entities.indices {
                entities[index] = try normalizeEntity(
                    entities[index],
                    path: "write_bible.\(collection)[\(index)]"
                )
                if collection == "locations" {
                    entities[index]["view_purpose"] = try keyedStrings(
                        entities[index]["view_purpose"],
                        key: "view",
                        value: "purpose",
                        path: "write_bible.locations[\(index)].view_purpose"
                    )
                }
            }
            payload[collection] = entities
        }

        let bible: Bible = try decodeArtifact(
            payload,
            as: Bible.self,
            label: "bible"
        )
        for path in bibleReferencePaths(bible) {
            try requireProjectImage(
                path,
                dataRoot: root,
                field: "bible anchor"
            )
        }
        try requireGeneratedPipelineAssets(
            bibleGeneratedPaths(bible),
            scope: "bible",
            dataRoot: root
        )
        try archiveExisting(PipelineLayout.bibleFile, dataRoot: root)
        do {
            try YAMLArtifactStore(dataRoot: root).save(
                bible,
                to: PipelineLayout.bibleFile
            )
        } catch {
            throw ToolError("Couldn't write bible: \(error)")
        }
        return try jsonResult([
            "written": true,
            "path": PipelineLayout.bibleFile,
            "characters": bible.characters.count,
            "ensembles": bible.ensembles.count,
            "props": bible.props.count,
            "locations": bible.locations.count,
        ])
    }

    func writeShotlistTool(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let brief: Brief
        do {
            brief = try YAMLArtifactStore(dataRoot: root).load(
                Brief.self,
                at: PipelineLayout.briefFile
            )
        } catch {
            throw ToolError("Can't write shot list without a valid brief: \(error)")
        }
        guard let mode = Mode(rawValue: brief.projectMode) else {
            throw ToolError("The brief has unsupported project_mode '\(brief.projectMode)'.")
        }
        let song = try measuredSong(dataRoot: root)

        var shots = args["shots"] as? [[String: Any]] ?? []
        for index in shots.indices {
            shots[index]["character_views"] = try keyedStrings(
                shots[index]["character_views"],
                key: "character",
                value: "view",
                path: "write_shotlist.shots[\(index)].character_views"
            )
            shots[index]["prop_views"] = try keyedStrings(
                shots[index]["prop_views"],
                key: "prop",
                value: "view",
                path: "write_shotlist.shots[\(index)].prop_views"
            )
        }
        let songData = try JSONEncoder().encode(song)
        let songObject = try JSONSerialization.jsonObject(with: songData)
        var payload: [String: Any] = [
            "schema": shotlistSchemaVersion,
            "mode": mode.rawValue,
            "project": projectName(dataRoot: root),
            "song": songObject,
            "generated": currentTimestamp(),
            "generator": Shotlist.agentWriterGenerator,
            "budget_eur": brief.budgetEur,
            "shots": shots,
        ]
        if let notes = args.string("notes") {
            payload["notes"] = notes
        }
        let shotlist: Shotlist = try decodeArtifact(
            payload,
            as: Shotlist.self,
            label: "shot list"
        )
        guard let executionObjects = args["execution_shots"] as? [[String: Any]] else {
            throw ToolError("execution_shots is required and must cover every shot exactly once.")
        }
        let executionInputs: [PipelineExecutionShotInput]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: executionObjects,
                options: [.sortedKeys]
            )
            executionInputs = try JSONDecoder().decode(
                [PipelineExecutionShotInput].self,
                from: data
            )
        } catch {
            throw ToolError("The execution plan input is invalid: \(error.localizedDescription)")
        }
        let declaration = try mutationPackDeclaration(
            editor,
            dataRoot: root
        )
        let projectHome = FrameInventory.projectHome(of: root)
        let workingHome = editor.workingRoot?
            .standardizedFileURL.resolvingSymlinksInPath()
        let marksWorkingCopyDirty = editor.openWorkingCopyKey != nil
            && workingHome == projectHome.standardizedFileURL.resolvingSymlinksInPath()
        let written = try ProjectWorkingCopy.transactProject(
            at: projectHome,
            markDirty: marksWorkingCopyDirty,
            validateCurrent: { currentHome in
                _ = try ProjectPackGate.requireMutation(
                    projectURL: currentHome,
                    declaredPack: declaration.packName,
                    declaredBinding: declaration.binding
                )
            }
        ) { stagingHome in
            guard let stagingRoot = DataRootResolver.dataRoot(of: stagingHome) else {
                throw ToolError(
                    "The staged project pipeline is unavailable. Reopen the project before writing."
                )
            }
            let url = try PipelineShotlistWriter.write(
                shotlist,
                executionInputs: executionInputs,
                dataRoot: stagingRoot,
                declaredPack: declaration.packName,
                declaredBinding: declaration.binding
            )
            try PipelinePhaseMutationRecorder.record(
                phase: "shotlist",
                dataRoot: stagingRoot,
                captureLineage: true,
                declaredPack: declaration.packName,
                declaredBinding: declaration.binding
            )
            return (
                path: relativePath(url, dataRoot: stagingRoot),
                version: latestShotlistVersion(dataRoot: stagingRoot) ?? 0
            )
        }
        return try jsonResult([
            "written": true,
            "version": written.version,
            "path": written.path,
            "shots": shotlist.shots.count,
            "execution_plan": PipelineLayout.executionPlanFile,
            "mode": shotlist.mode.rawValue,
            "duration_s": shotlist.song.durationS,
            "bpm": shotlist.song.bpm,
            "tempo_multiplier": shotlist.song.tempoMultiplier,
        ])
    }

    private func normalizeEntity(
        _ entity: [String: Any],
        path: String
    ) throws -> [String: Any] {
        var entity = entity
        entity["attributes"] = try keyedStrings(
            entity["attributes"],
            key: "key",
            value: "value",
            path: "\(path).attributes"
        )
        entity["sheets"] = try keyedStrings(
            entity["sheets"],
            key: "view",
            value: "path",
            path: "\(path).sheets"
        )
        return entity
    }

    private func keyedStrings(
        _ value: Any?,
        key: String,
        value valueKey: String,
        path: String
    ) throws -> [String: String] {
        guard let entries = value as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for (index, entry) in entries.enumerated() {
            guard let name = entry[key] as? String,
                  let value = entry[valueKey] as? String else {
                throw ToolError("\(path)[\(index)] is malformed.")
            }
            guard result[name] == nil else {
                throw ToolError("\(path) contains duplicate key '\(name)'.")
            }
            result[name] = value
        }
        return result
    }

    private func decodeArtifact<T: Decodable>(
        _ payload: [String: Any],
        as type: T.Type,
        label: String
    ) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ToolError("\(label) rejected: \(error). Nothing was written.")
        }
    }

    private func measuredSong(dataRoot: URL) throws -> Song {
        let measured = try currentMeasuredAnalysis(dataRoot: dataRoot)
        let analysisURL = measured.url
        let object = measured.object
        guard let bpm = (object["bpm"] as? NSNumber)?.doubleValue,
              let duration = (object["duration_s"] as? NSNumber)?.doubleValue,
              bpm > 0,
              duration > 0 else {
            throw ToolError(
                "Can't write shot list without measured analysis containing positive bpm and duration_s."
            )
        }
        let songURL = measured.song
        let audioPath = relativePath(songURL, dataRoot: dataRoot)
        let lyricsURL = dataRoot.appendingPathComponent("lyrics/lyrics.txt")
        let lyricsPath = FileManager.default.fileExists(atPath: lyricsURL.path)
            ? relativePath(lyricsURL, dataRoot: dataRoot)
            : nil
        do {
            return try Song(
                title: songURL.deletingPathExtension().lastPathComponent,
                audioPath: audioPath,
                lyricsPath: lyricsPath,
                analysisPath: relativePath(analysisURL, dataRoot: dataRoot),
                bpm: bpm,
                tempoMultiplier: (object["tempo_multiplier"] as? NSNumber)?.doubleValue ?? 1,
                durationS: duration
            )
        } catch {
            throw ToolError("Measured song data is invalid: \(error)")
        }
    }

    private func currentMeasuredAnalysis(
        dataRoot: URL
    ) throws -> (url: URL, object: [String: Any], song: URL) {
        let songFiles = AudioProjectLayout.songFiles(dataRoot: dataRoot)
        guard songFiles.count == 1, let songURL = songFiles.first,
              let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(
                dataRoot: dataRoot
              ) else {
            throw ToolError(
                "The measured analysis does not belong to exactly one current project track. "
                    + "Attach one track and re-run run_phase(\"analysis\")."
            )
        }
        let object: [String: Any]
        do {
            let data = try Data(contentsOf: analysisURL)
            guard let decoded = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw ToolError("The measured analysis is not a JSON object.")
            }
            object = decoded
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError(
                "Can't read the measured analysis. Run run_phase(\"analysis\") first: \(error)"
            )
        }
        let expectedPath = relativePath(songURL, dataRoot: dataRoot)
        let expectedHash: String
        do {
            expectedHash = try FileDigest.sha256(of: songURL)
        } catch {
            throw ToolError(
                "Can't fingerprint the current project track. Re-attach it before analysis: \(error)"
            )
        }
        guard object["schema"] as? String == PipelineArtifactWriteContract.measuredAnalysisSchemaVersion,
              object["project"] as? String == projectName(dataRoot: dataRoot),
              object["song_path"] as? String == expectedPath,
              object["song_sha256"] as? String == expectedHash else {
            throw ToolError(
                "The measured analysis does not belong to the current project track. "
                    + "Re-run run_phase(\"analysis\") before continuing."
            )
        }
        return (analysisURL, object, songURL)
    }

    private func projectName(dataRoot: URL) -> String {
        FrameInventory.projectName(of: dataRoot)
            ?? FrameInventory.projectHome(of: dataRoot).lastPathComponent
    }

    private func relativePath(_ url: URL, dataRoot: URL) -> String {
        FrameInventory.relativePath(of: url, to: dataRoot)
    }

    private func requireProjectFile(
        _ path: String,
        dataRoot: URL,
        field: String
    ) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError("\(field) contains an empty path.")
        }
        guard !trimmed.hasPrefix("/"),
              !trimmed.split(separator: "/").contains("..") else {
            throw ToolError("\(field) must be a project-relative path: '\(trimmed)'.")
        }
        guard projectFileURL(trimmed, dataRoot: dataRoot) != nil else {
            throw ToolError(
                "\(field) must name a real file inside the project: '\(trimmed)'."
            )
        }
    }

    private func requireProjectImage(
        _ path: String,
        dataRoot: URL,
        field: String
    ) throws {
        try requireProjectFile(path, dataRoot: dataRoot, field: field)
        guard let url = projectFileURL(path, dataRoot: dataRoot),
              ClipType(
                fileExtension: url.pathExtension.lowercased()
              ) == .image else {
            throw ToolError("\(field) must name an image inside the project: '\(path)'.")
        }
    }

    private func projectFileURL(
        _ path: String,
        dataRoot: URL
    ) -> URL? {
        let home = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        for candidate in [
            dataRoot.appendingPathComponent(path),
            home.appendingPathComponent(path),
        ] {
            let resolved = candidate.standardizedFileURL
                .resolvingSymlinksInPath()
            guard resolved.path == home.path
                    || resolved.path.hasPrefix(home.path + "/") else {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue {
                return resolved
            }
        }
        return nil
    }

    private func requireGeneratedPipelineAssets(
        _ paths: [String],
        scope: String,
        dataRoot: URL
    ) throws {
        let proof: PipelineAssetProof
        do {
            proof = try loadPipelineAssetProof(
                dataRoot: dataRoot,
                scope: scope
            )
        } catch {
            throw ToolError(
                "\(scope) generation provenance is invalid: \(error)"
            )
        }
        guard proof.schema == pipelineAssetProofSchemaVersion,
              proof.scope == scope,
              proof.project == projectName(dataRoot: dataRoot) else {
            throw ToolError(
                "\(scope) generation provenance has the wrong project, scope, or schema."
            )
        }
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
                  let url = projectFileURL(path, dataRoot: dataRoot),
                  let current = try? FileDigest.sha256(of: url)
            else { return true }
            return current != entry.sha256
        }
        guard invalid.isEmpty else {
            throw ToolError(
                "\(invalid.count) generated \(scope) asset(s) lack current "
                    + "host-recorded prompt/model provenance (e.g. "
                    + "\(invalid.prefix(3).joined(separator: ", ")))."
            )
        }
    }

    private func bibleReferencePaths(_ bible: Bible) -> [String] {
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
        return paths
    }

    private func bibleGeneratedPaths(_ bible: Bible) -> [String] {
        var paths = bible.characters.flatMap {
            Array($0.sheets.values)
        }
        paths += bible.ensembles.flatMap {
            Array($0.sheets.values)
        }
        paths += bible.props.flatMap {
            Array($0.sheets.values)
        }
        paths += bible.locations.flatMap {
            Array($0.sheets.values)
                + ($0.scene3d.panorama.isEmpty
                    ? []
                    : [$0.scene3d.panorama])
        }
        return paths
    }

    func archiveExisting(_ relative: String, dataRoot: URL) throws {
        let source = PipelineLayout.url(relative, in: dataRoot)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let history = source.deletingLastPathComponent()
            .appendingPathComponent("history", isDirectory: true)
        let stamp = currentTimestamp()
            .replacingOccurrences(of: ":", with: "-")
        let destination = history.appendingPathComponent(
            "\(source.deletingPathExtension().lastPathComponent)-\(stamp)-\(UUID().uuidString).\(source.pathExtension)"
        )
        do {
            try FileManager.default.createDirectory(
                at: history,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw ToolError("Couldn't preserve the previous \(relative): \(error)")
        }
    }
}
