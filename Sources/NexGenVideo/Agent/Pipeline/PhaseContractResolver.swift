import Foundation
import NexGenEngine

struct ResolvedPhaseContract: Sendable {
    struct Phase: Sendable {
        let declaration: PackPipelineManifest.Phase
        let phaseBoundCapabilities: Set<ToolName>
        let supportingCapabilities: Set<ToolName>
        let nativeLineageProvider: EngineRegistry.PhaseLineageProvider?
        let nativeLineageRequiresRecord: Bool
    }

    let packID: String
    let packVersion: String
    let engineContract: Int
    let historicalCompatibility: Bool
    let manifest: PackPipelineManifest
    let hardSteps: HardStepManifest
    let resourceRoot: URL
    let phases: [Phase]

    var order: [String] { phases.map(\.declaration.id) }

    func phase(_ id: String) -> Phase? {
        phases.first { $0.declaration.id == id }
    }

    func allowsPhaseBound(_ tool: ToolName, phase: String) -> Bool {
        self.phase(phase)?.phaseBoundCapabilities.contains(tool) == true
    }

    func allowsSupporting(_ tool: ToolName, phase: String) -> Bool {
        self.phase(phase)?.supportingCapabilities.contains(tool) == true
    }

    func allowsPostPipeline(_ tool: ToolName) -> Bool {
        manifest.postPipelineCapabilities.contains(tool.rawValue)
    }

    func instructions(for phase: String) throws -> String {
        guard let declaration = self.phase(phase)?.declaration else {
            throw PhaseContractError.unknownPhase(phase)
        }
        let url = try PackResourceLocator.file(
            declaration.instructions,
            inside: resourceRoot
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}

enum PhaseContractError: Swift.Error, LocalizedError, Sendable, Equatable {
    case malformed(String)
    case missingResource(String)
    case registryMismatch(String)
    case unsupportedHistoricalPack(id: String, version: String, engineContract: Int)
    case unknownPhase(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            return "Invalid pipeline contract — \(detail)."
        case .missingResource(let resource):
            return "Invalid pipeline contract — required resource \"\(resource)\" is missing."
        case .registryMismatch(let detail):
            return "Invalid pipeline contract — \(detail)."
        case .unsupportedHistoricalPack(let id, let version, let engineContract):
            return "The exact historical pack \(id) \(version) (engine contract \(engineContract)) has no supported pipeline contract."
        case .unknownPhase(let phase):
            return "The pipeline contract has no phase named \"\(phase)\"."
        case .unavailable(let pack):
            return "The \(pack) workflow contract is unavailable. Reopen the project before continuing."
        }
    }
}

enum PackResourceLocator {
    static func root(bundleURL: URL, relativePath: String) throws -> URL {
        let resources = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let root = try containedURL(relativePath, inside: resources)
        let values: URLResourceValues
        do {
            values = try root.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw PhaseContractError.missingResource(relativePath)
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PhaseContractError.missingResource(relativePath)
        }
        return root
    }

    static func file(_ relativePath: String, inside root: URL) throws -> URL {
        let url = try containedURL(relativePath, inside: root)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw PhaseContractError.missingResource(relativePath)
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PhaseContractError.missingResource(relativePath)
        }
        return url
    }

    static func validateRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func containedURL(_ relativePath: String, inside root: URL) throws -> URL {
        guard validateRelativePath(relativePath) else {
            throw PhaseContractError.malformed("unsafe resource path \"\(relativePath)\"")
        }
        let standardizedRoot = root.standardizedFileURL
        let rootValues: URLResourceValues
        do {
            rootValues = try standardizedRoot.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw PhaseContractError.missingResource(relativePath)
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw PhaseContractError.malformed("resource root is not a real directory")
        }
        var candidate = standardizedRoot
        for component in relativePath.split(separator: "/") {
            candidate.appendPathComponent(String(component))
            if FileManager.default.fileExists(atPath: candidate.path) {
                let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw PhaseContractError.malformed("resource path traverses a symbolic link")
                }
            }
        }
        candidate = candidate.standardizedFileURL
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let prefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard resolvedCandidate.path.hasPrefix(prefix) else {
            throw PhaseContractError.malformed("resource path escapes the pack")
        }
        return candidate
    }
}

struct PhaseContractHostRegistry: Sendable {
    struct WriterSelector: Sendable {
        let expectedPhase: String?
        let requiredTools: Set<ToolName>
    }

    static let genericSelector = "host.generic_json_extension"

    let artifactSelectors: [String: String]
    let writerSelectors: [String: WriterSelector]
    let hostRunnerSelectors: [String: String]

    static let live = PhaseContractHostRegistry(
        artifactSelectors: [
            "host.project_track": "project_init",
            "host.analysis": "analysis",
            "host.brief": "brief",
            "host.production_design": "production_design",
            "host.treatment": "treatment",
            "host.storyboard": "storyboard",
            "host.bible": "bible",
            "host.shotlist": "shotlist",
            "host.sanity_report": "sanity",
            "host.frames_manifest": "frames",
            "host.render_manifest": "render",
        ],
        writerSelectors: [
            "host.project_init_intake": .init(
                expectedPhase: "project_init",
                requiredTools: []
            ),
            "host.analysis_writer": .init(
                expectedPhase: "analysis",
                requiredTools: [.runPhase, .writeAnalysisInterpretation]
            ),
            "host.brief_writer": .init(
                expectedPhase: "brief",
                requiredTools: [.writeBrief]
            ),
            "host.production_design_writer": .init(
                expectedPhase: "production_design",
                requiredTools: [.writeProductionDesign]
            ),
            "host.treatment_writer": .init(
                expectedPhase: "treatment",
                requiredTools: [.writeTreatment]
            ),
            "host.storyboard_writer": .init(
                expectedPhase: "storyboard",
                requiredTools: [.writeStoryboard]
            ),
            "host.bible_writer": .init(
                expectedPhase: "bible",
                requiredTools: [.writeBible]
            ),
            "host.shotlist_writer": .init(
                expectedPhase: "shotlist",
                requiredTools: [.writeShotlist]
            ),
            "host.sanity_runner": .init(
                expectedPhase: "sanity",
                requiredTools: [.runSanity]
            ),
            "host.frames_writer": .init(
                expectedPhase: "frames",
                requiredTools: [.runPhase, .recordRender, .saveFrameAudit]
            ),
            "host.render_writer": .init(
                expectedPhase: "render",
                requiredTools: [.runPhase, .recordRender]
            ),
            genericSelector: .init(
                expectedPhase: nil,
                requiredTools: [.writePhaseExtension]
            ),
        ],
        hostRunnerSelectors: [
            "host.frames_runner": "frames",
            "host.render_runner": "render",
        ]
    )
}

enum PhaseContractResolver {
    static func resolve(
        manifest: PackPipelineManifest,
        packVersion: String,
        engineContract: Int,
        resourceRoot: URL,
        hardSteps: HardStepManifest,
        registry: EngineRegistry,
        historicalCompatibility: Bool = false,
        host: PhaseContractHostRegistry = .live
    ) throws -> ResolvedPhaseContract {
        try validateStructure(
            manifest,
            resourceRoot: resourceRoot,
            hardSteps: hardSteps,
            allowsMissingLineage: historicalCompatibility && engineContract == 2
        )
        let knownTools = Set(ToolDefinitions.all.map(\.name))
        var resolvedPhases: [ResolvedPhaseContract.Phase] = []

        for phase in manifest.phases {
            let phaseBound = try tools(
                phase.capabilities.phaseBound,
                known: knownTools,
                context: "\(phase.id) phase-bound capabilities"
            )
            let supporting = try tools(
                phase.capabilities.supporting,
                known: knownTools,
                context: "\(phase.id) supporting capabilities"
            )
            guard phaseBound.isDisjoint(with: supporting) else {
                throw PhaseContractError.malformed(
                    "\(phase.id) declares a tool as both phase-bound and supporting"
                )
            }
            for tool in phaseBound where advancingPhase(for: tool, declaredPhase: phase.id) != phase.id {
                throw PhaseContractError.registryMismatch(
                    "\(phase.id) grants phase-bound tool \(tool.rawValue) outside its host guard"
                )
            }
            if supporting.contains(where: { !$0.usesCurrentPipelinePhase }) {
                throw PhaseContractError.registryMismatch(
                    "\(phase.id) grants a supporting tool without a current-phase host guard"
                )
            }
            if phaseBound.contains(.writePhaseExtension), phase.extensionArtifact == nil {
                throw PhaseContractError.registryMismatch(
                    "\(phase.id) grants write_phase_extension without an extension artifact"
                )
            }
            try validateSelectors(
                phase,
                phaseBound: phaseBound,
                registry: registry,
                host: host
            )
            let nativeLineageProvider: EngineRegistry.PhaseLineageProvider?
            let nativeLineageRequiresRecord: Bool
            if phase.selectors.lineage == "registry.\(phase.id)" {
                nativeLineageProvider = registry.phaseLineageProviders[phase.id]
                nativeLineageRequiresRecord = true
            } else if phase.id == "project_init", phase.selectors.lineage == nil {
                let steps = hardSteps.steps(for: phase.id)
                nativeLineageProvider = { dataRoot in
                    try HostPhaseIntakeLineage.snapshot(
                        steps: steps,
                        dataRoot: dataRoot
                    )
                }
                nativeLineageRequiresRecord = false
            } else {
                nativeLineageProvider = nil
                nativeLineageRequiresRecord = true
            }
            resolvedPhases.append(
                .init(
                    declaration: phase,
                    phaseBoundCapabilities: phaseBound,
                    supportingCapabilities: supporting,
                    nativeLineageProvider: nativeLineageProvider,
                    nativeLineageRequiresRecord: nativeLineageRequiresRecord
                )
            )
        }

        let postPipeline = try tools(
            manifest.postPipelineCapabilities,
            known: knownTools,
            context: "post-pipeline capabilities"
        )
        if postPipeline.contains(where: { !$0.usesCurrentPipelinePhase }) {
            throw PhaseContractError.registryMismatch(
                "post-pipeline capabilities include a tool without a current-phase host guard"
            )
        }
        try validateRegistryCoverage(
            manifest: manifest,
            registry: registry,
            allowsHistoricalLineageGap: historicalCompatibility && engineContract == 2
        )

        return ResolvedPhaseContract(
            packID: manifest.packID,
            packVersion: packVersion,
            engineContract: engineContract,
            historicalCompatibility: historicalCompatibility,
            manifest: manifest,
            hardSteps: hardSteps,
            resourceRoot: resourceRoot,
            phases: resolvedPhases
        )
    }

    static func validateStructure(
        _ manifest: PackPipelineManifest,
        resourceRoot: URL,
        hardSteps: HardStepManifest,
        allowsMissingLineage: Bool = false
    ) throws {
        guard manifest.schema == PackPipelineManifest.currentSchema else {
            throw PhaseContractError.malformed("unsupported schema \"\(manifest.schema)\"")
        }
        guard validIdentifier(manifest.contractID), validIdentifier(manifest.packID) else {
            throw PhaseContractError.malformed("contract and pack IDs must be stable identifiers")
        }
        guard PackResourceLocator.validateRelativePath(manifest.resourceRoot) else {
            throw PhaseContractError.malformed("resourceRoot is unsafe")
        }
        guard manifest.hardStepsManifestID == hardSteps.schema else {
            throw PhaseContractError.malformed(
                "hard-step reference \(manifest.hardStepsManifestID) does not match \(hardSteps.schema)"
            )
        }
        guard !manifest.display.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhaseContractError.malformed("display title is empty")
        }
        if let table = manifest.display.localizationTable,
           table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PhaseContractError.malformed("display localization table is empty")
        }
        try requireUnique(manifest.policyIDs, context: "pack policy IDs")
        guard manifest.policyIDs.allSatisfy(validIdentifier) else {
            throw PhaseContractError.malformed("pack policy IDs are invalid")
        }
        try requireUnique(
            manifest.postPipelineCapabilities,
            context: "post-pipeline capabilities"
        )
        guard !manifest.phases.isEmpty else {
            throw PhaseContractError.malformed("phases is empty")
        }

        let ids = manifest.phases.map(\.id)
        try requireUnique(ids, context: "phase IDs")
        let expectedIndices = Array(manifest.phases.indices)
        guard manifest.phases.map(\.executionIndex) == expectedIndices else {
            throw PhaseContractError.malformed(
                "executionIndex values must be unique, contiguous, and declaration-ordered from zero"
            )
        }
        for (index, phase) in manifest.phases.enumerated() {
            guard validPhaseID(phase.id) else {
                throw PhaseContractError.malformed("invalid phase ID \"\(phase.id)\"")
            }
            let expectedDependencies = index == 0 ? [] : [manifest.phases[index - 1].id]
            guard phase.dependencies == expectedDependencies else {
                throw PhaseContractError.malformed(
                    "\(phase.id) dependencies must be exactly \(expectedDependencies) for the V1 total order"
                )
            }
            try requireUnique(phase.roles.map(\.rawValue), context: "\(phase.id) roles")
            guard phase.roles.contains(.canonicalWriter) else {
                throw PhaseContractError.malformed("\(phase.id) has no canonical writer role")
            }
            guard phase.roles.contains(.reviewGate) else {
                throw PhaseContractError.malformed("\(phase.id) has no review/gate role")
            }
            guard !phase.selectors.artifact.isEmpty,
                  !phase.selectors.writer.isEmpty,
                  !phase.selectors.gate.isEmpty else {
                throw PhaseContractError.malformed(
                    "\(phase.id) is missing an artifact, writer, or gate selector"
                )
            }
            if index > 0,
               phase.selectors.lineage == nil,
               !allowsMissingLineage {
                throw PhaseContractError.malformed(
                    "\(phase.id) has no lineage selector"
                )
            }
            let hasRunnerRole = phase.roles.contains(.deterministicRunner)
            guard hasRunnerRole == (phase.selectors.runner != nil) else {
                throw PhaseContractError.malformed(
                    "\(phase.id) deterministic runner role and selector disagree"
                )
            }
            if !hasRunnerRole, !phase.selectors.deterministicSteps.isEmpty {
                throw PhaseContractError.malformed(
                    "\(phase.id) declares deterministic steps without a runner"
                )
            }
            try requireUnique(
                phase.selectors.deterministicSteps,
                context: "\(phase.id) deterministic steps"
            )
            try requireUnique(
                phase.capabilities.phaseBound,
                context: "\(phase.id) phase-bound capabilities"
            )
            try requireUnique(
                phase.capabilities.supporting,
                context: "\(phase.id) supporting capabilities"
            )
            try requireUnique(phase.policyIDs, context: "\(phase.id) policy IDs")
            guard phase.policyIDs.allSatisfy(validIdentifier) else {
                throw PhaseContractError.malformed("\(phase.id) policy IDs are invalid")
            }
            if let display = phase.display {
                guard !display.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PhaseContractError.malformed("\(phase.id) display label is empty")
                }
                if let key = display.localizationKey,
                   key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw PhaseContractError.malformed(
                        "\(phase.id) display localization key is empty"
                    )
                }
            }
            guard !phase.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PhaseContractError.malformed("\(phase.id) has no runtime instructions")
            }
            let instructionURL = try PackResourceLocator.file(
                phase.instructions,
                inside: resourceRoot
            )
            let instructions = try String(contentsOf: instructionURL, encoding: .utf8)
            guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PhaseContractError.malformed("\(phase.id) runtime instructions are empty")
            }
            if let extensionArtifact = phase.extensionArtifact {
                guard phase.selectors.artifact == PhaseContractHostRegistry.genericSelector,
                      phase.selectors.writer == PhaseContractHostRegistry.genericSelector,
                      phase.selectors.gate == PhaseContractHostRegistry.genericSelector,
                      phase.selectors.lineage == PhaseContractHostRegistry.genericSelector else {
                    throw PhaseContractError.malformed(
                        "\(phase.id) extension artifact must use the generic host selectors"
                    )
                }
                guard extensionArtifact.relativePath.hasPrefix("extensions/"),
                      extensionArtifact.relativePath.hasSuffix(".json"),
                      PackResourceLocator.validateRelativePath(extensionArtifact.relativePath),
                      PackResourceLocator.validateRelativePath(extensionArtifact.schemaResource) else {
                    throw PhaseContractError.malformed(
                        "\(phase.id) extension artifact paths are invalid"
                    )
                }
                let schemaURL = try PackResourceLocator.file(
                    extensionArtifact.schemaResource,
                    inside: resourceRoot
                )
                _ = try PhaseExtensionSchema.load(from: schemaURL)
            } else if [
                phase.selectors.artifact,
                phase.selectors.writer,
                phase.selectors.gate,
                phase.selectors.lineage ?? "",
            ].contains(PhaseContractHostRegistry.genericSelector) {
                throw PhaseContractError.malformed(
                    "\(phase.id) uses a generic selector without extensionArtifact"
                )
            }
        }

        try requireUnique(
            manifest.phases.compactMap {
                $0.extensionArtifact?.relativePath
                    .precomposedStringWithCanonicalMapping
                    .folding(
                        options: [.caseInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    )
                    .precomposedStringWithCanonicalMapping
            },
            context: "extension artifact paths"
        )

        let knownPhases = Set(ids)
        try requireUnique(hardSteps.declaredPhases, context: "hard-step phase declarations")
        guard Set(hardSteps.declaredPhases).isSubset(of: knownPhases) else {
            throw PhaseContractError.malformed("hard steps declare an unknown phase")
        }
        let hardStepPhases = Set(hardSteps.allSteps.map(\.phase))
        guard hardStepPhases.isSubset(of: knownPhases) else {
            throw PhaseContractError.malformed("hard steps reference an unknown phase")
        }
        let intakePhases = Set(
            manifest.phases.filter { $0.roles.contains(.intake) }.map(\.id)
        )
        guard hardStepPhases == intakePhases else {
            throw PhaseContractError.malformed(
                "intake roles and hard-step phases must match exactly"
            )
        }
        let kindOwners = Dictionary(grouping: hardSteps.allSteps, by: \.kind)
        guard kindOwners.values.allSatisfy({ steps in
            Set(steps.map(\.phase)).count == 1
        }) else {
            throw PhaseContractError.malformed(
                "each intake kind must be owned by exactly one phase"
            )
        }
        try requireUnique(hardSteps.allSteps.map(\.id), context: "hard-step IDs")
    }

    private static func validateSelectors(
        _ phase: PackPipelineManifest.Phase,
        phaseBound: Set<ToolName>,
        registry: EngineRegistry,
        host: PhaseContractHostRegistry
    ) throws {
        if phase.selectors.artifact != PhaseContractHostRegistry.genericSelector {
            guard host.artifactSelectors[phase.selectors.artifact] == phase.id else {
                throw PhaseContractError.registryMismatch(
                    "unknown artifact selector \(phase.selectors.artifact) for \(phase.id)"
                )
            }
        }
        guard let writer = host.writerSelectors[phase.selectors.writer],
              (writer.expectedPhase == phase.id
                  || (writer.expectedPhase == nil
                      && phase.selectors.writer == PhaseContractHostRegistry.genericSelector)),
              writer.requiredTools.isSubset(of: phaseBound) else {
            throw PhaseContractError.registryMismatch(
                "writer selector \(phase.selectors.writer) is unknown or not granted by \(phase.id)"
            )
        }
        if let runner = phase.selectors.runner {
            if runner.hasPrefix("registry.") {
                let id = String(runner.dropFirst("registry.".count))
                guard id == phase.id,
                      registry.phases[id] != nil || registry.progressPhaseRunners[id] != nil else {
                    throw PhaseContractError.registryMismatch(
                        "runner selector \(runner) is not registered"
                    )
                }
            } else {
                guard host.hostRunnerSelectors[runner] == phase.id else {
                    throw PhaseContractError.registryMismatch(
                        "host runner selector \(runner) is unknown for \(phase.id)"
                    )
                }
            }
        }
        if phase.selectors.gate != PhaseContractHostRegistry.genericSelector {
            guard phase.selectors.gate == "registry.\(phase.id)",
                  registry.gateRequirements[phase.id] != nil else {
                throw PhaseContractError.registryMismatch(
                    "gate selector \(phase.selectors.gate) is not registered"
                )
            }
        }
        if let lineage = phase.selectors.lineage,
           lineage != PhaseContractHostRegistry.genericSelector {
            guard lineage == "registry.\(phase.id)",
                  registry.phaseLineageProviders[phase.id] != nil else {
                throw PhaseContractError.registryMismatch(
                    "lineage selector \(lineage) is not registered"
                )
            }
        }
        let registeredSteps = registry.deterministicSteps(forPhase: phase.id).map(\.id)
        guard registeredSteps == phase.selectors.deterministicSteps else {
            throw PhaseContractError.registryMismatch(
                "\(phase.id) deterministic-step selectors do not match the registry"
            )
        }
    }

    private static func validateRegistryCoverage(
        manifest: PackPipelineManifest,
        registry: EngineRegistry,
        allowsHistoricalLineageGap: Bool
    ) throws {
        let phases = Set(manifest.phases.map(\.id))
        let registeredRunnerPhases = Set(registry.phases.keys)
            .union(registry.progressPhaseRunners.keys)
        let selectedRunnerPhases = Set(manifest.phases.compactMap { phase in
            phase.selectors.runner?.hasPrefix("registry.") == true ? phase.id : nil
        })
        guard registeredRunnerPhases == selectedRunnerPhases else {
            throw PhaseContractError.registryMismatch(
                "manifest and registry runner selectors differ"
            )
        }
        let registeredGatePhases = Set(registry.gateRequirements.keys)
        let selectedGatePhases = Set(manifest.phases.compactMap { phase in
            phase.selectors.gate.hasPrefix("registry.") ? phase.id : nil
        })
        guard registeredGatePhases == selectedGatePhases else {
            throw PhaseContractError.registryMismatch(
                "manifest and registry gate selectors differ"
            )
        }
        let registeredLineagePhases = Set(registry.phaseLineageProviders.keys)
        let selectedLineagePhases = Set(manifest.phases.compactMap { phase in
            phase.selectors.lineage?.hasPrefix("registry.") == true ? phase.id : nil
        })
        if allowsHistoricalLineageGap {
            guard selectedLineagePhases.isSubset(of: registeredLineagePhases),
                  registeredLineagePhases.isSubset(of: phases) else {
                throw PhaseContractError.registryMismatch(
                    "historical manifest and registry lineage selectors differ"
                )
            }
        } else if registeredLineagePhases != selectedLineagePhases {
            throw PhaseContractError.registryMismatch(
                "manifest and registry lineage selectors differ"
            )
        }
        guard Set(registry.deterministicSteps.map(\.phase)).isSubset(of: phases) else {
            throw PhaseContractError.registryMismatch(
                "the registry contains a deterministic step outside the manifest"
            )
        }
        for placement in registry.phasePlacements {
            guard let index = manifest.phases.firstIndex(where: {
                $0.id == placement.phase
            }) else {
                throw PhaseContractError.registryMismatch(
                    "legacy placement names unknown phase \(placement.phase)"
                )
            }
            let expectedPredecessor = index == 0
                ? nil
                : manifest.phases[index - 1].id
            guard phases.contains(placement.phase),
                  expectedPredecessor == placement.after else {
                throw PhaseContractError.registryMismatch(
                    "legacy placement for \(placement.phase) disagrees with the manifest order"
                )
            }
        }
    }

    private static func tools(
        _ values: [String],
        known: Set<ToolName>,
        context: String
    ) throws -> Set<ToolName> {
        var result = Set<ToolName>()
        for value in values {
            guard let tool = ToolName(rawValue: value), known.contains(tool) else {
                throw PhaseContractError.registryMismatch(
                    "\(context) names unknown host tool \(value)"
                )
            }
            result.insert(tool)
        }
        return result
    }

    private static func advancingPhase(
        for tool: ToolName,
        declaredPhase: String
    ) -> String? {
        let arguments: [String: Any]
        switch tool {
        case .runPhase, .writePhaseExtension:
            arguments = ["phase": declaredPhase]
        case .nextRenderShot, .recordRender:
            arguments = [
                "phase": declaredPhase == "render" ? "final" : declaredPhase,
            ]
        default:
            arguments = [:]
        }
        return tool.advancingPhase(args: arguments)
    }

    private static func requireUnique(_ values: [String], context: String) throws {
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(values).count == values.count else {
            throw PhaseContractError.malformed("\(context) must be non-empty and unique")
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z][A-Za-z0-9._-]*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func validPhaseID(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) != nil
    }
}

struct PhaseContractBundleIdentity: Sendable, Equatable {
    let id: String
    let version: String
    let engineContract: Int
    let pipelineContractVersion: Int
    let resourceRoot: String
}

enum HistoricalPhaseContractCompatibility {
    struct Key: Hashable, Sendable {
        let id: String
        let version: String
        let engineContract: Int
    }

    struct IntakeExpectation: Sendable, Equatable {
        let phase: String
        let kinds: [HardStep.Kind]
    }

    private struct Entry: Sendable {
        let version: String
        let engineContract: Int
        let resourceRoot: String
        let intake: [IntakeExpectation]
    }

    // Exact published tuples; missing or altered metadata never selects a nearby contract.
    private static let musicvideoVersions: [Entry] = [
        .init(
            version: "0.0.4",
            engineContract: 2,
            resourceRoot: "NexGenVideo_MusicvideoPlugin.bundle/MusicvideoPack",
            intake: [
                .init(phase: "project_init", kinds: [.script, .character, .location, .style]),
                .init(phase: "analysis", kinds: [.song, .lyrics]),
            ]
        ),
        modernEntry("0.0.16", engineContract: 4, nestedResources: true),
        modernEntry("0.1.0", engineContract: 5, nestedResources: true),
        modernEntry("0.2.0", engineContract: 8),
        modernEntry("0.3.0", engineContract: 8),
        modernEntry("0.4.0", engineContract: 8),
        modernEntry("0.4.1", engineContract: 8),
        modernEntry("0.4.2", engineContract: 8),
        modernEntry("0.4.3", engineContract: 8),
        modernEntry("0.4.4", engineContract: 8),
        modernEntry("0.4.5", engineContract: 8),
    ]

    static func manifest(for key: Key) -> PackPipelineManifest? {
        guard let entry = entry(for: key) else { return nil }
        return musicvideoManifest(
            resourceRoot: entry.resourceRoot,
            supportsModernHarness: key.engineContract >= 4,
            intakePhases: Set(entry.intake.map(\.phase))
        )
    }

    static func resourceRoot(for key: Key) -> String? {
        entry(for: key)?.resourceRoot
    }

    static func intake(for key: Key) -> [IntakeExpectation]? {
        entry(for: key)?.intake
    }

    private static func entry(for key: Key) -> Entry? {
        guard key.id == "musicvideo" else { return nil }
        return musicvideoVersions.first {
            $0.version == key.version && $0.engineContract == key.engineContract
        }
    }

    private static func modernEntry(
        _ version: String,
        engineContract: Int,
        nestedResources: Bool = false
    ) -> Entry {
        Entry(
            version: version,
            engineContract: engineContract,
            resourceRoot: nestedResources
                ? "NexGenVideo_MusicvideoPlugin.bundle/MusicvideoPack"
                : "MusicvideoPack",
            intake: [
                .init(phase: "project_init", kinds: [.song, .lyrics]),
                .init(phase: "brief", kinds: [.script, .character, .location, .style]),
            ]
        )
    }

    private static func musicvideoManifest(
        resourceRoot: String,
        supportsModernHarness: Bool,
        intakePhases: Set<String>
    ) -> PackPipelineManifest {
        let phases = PipelineAgentContract.musicvideoPhases.enumerated().map { index, id in
            PackPipelineManifest.Phase(
                id: id,
                executionIndex: index,
                dependencies: index == 0 ? [] : [PipelineAgentContract.musicvideoPhases[index - 1]],
                roles: roles(for: id, intakePhases: intakePhases),
                selectors: selectors(
                    for: id,
                    supportsModernHarness: supportsModernHarness
                ),
                capabilities: .init(
                    phaseBound: (PipelineAgentContract.executableTools[id] ?? [])
                        .map(\.rawValue).sorted(),
                    supporting: (PipelineAgentContract.currentPhaseCapabilities[id] ?? [])
                        .map(\.rawValue).sorted()
                ),
                instructions: "phases/\(PipelineAgentContract.phaseDocumentName(id)).md",
                display: .init(label: label(for: id))
            )
        }
        return PackPipelineManifest(
            contractID: "musicvideo.pipeline.v1",
            packID: "musicvideo",
            resourceRoot: resourceRoot,
            hardStepsManifestID: "hardsteps/1.0",
            display: .init(title: "Music Video"),
            postPipelineCapabilities: PipelineAgentContract.postPipelineUtilityCapabilities
                .map(\.rawValue).sorted(),
            phases: phases
        )
    }

    private static func roles(
        for phase: String,
        intakePhases: Set<String>
    ) -> [PackPipelineManifest.Role] {
        var roles: [PackPipelineManifest.Role] = []
        if intakePhases.contains(phase) { roles.append(.intake) }
        if phase == "analysis" || phase == "frames" || phase == "render" {
            roles.append(.deterministicRunner)
        }
        roles.append(.canonicalWriter)
        roles.append(.reviewGate)
        return roles
    }

    private static func selectors(
        for phase: String,
        supportsModernHarness: Bool
    ) -> PackPipelineManifest.Selectors {
        let artifact: [String: String] = [
            "project_init": "host.project_track",
            "analysis": "host.analysis",
            "brief": "host.brief",
            "production_design": "host.production_design",
            "treatment": "host.treatment",
            "storyboard": "host.storyboard",
            "bible": "host.bible",
            "shotlist": "host.shotlist",
            "sanity": "host.sanity_report",
            "frames": "host.frames_manifest",
            "render": "host.render_manifest",
        ]
        let writer: [String: String] = [
            "project_init": "host.project_init_intake",
            "analysis": "host.analysis_writer",
            "brief": "host.brief_writer",
            "production_design": "host.production_design_writer",
            "treatment": "host.treatment_writer",
            "storyboard": "host.storyboard_writer",
            "bible": "host.bible_writer",
            "shotlist": "host.shotlist_writer",
            "sanity": "host.sanity_runner",
            "frames": "host.frames_writer",
            "render": "host.render_writer",
        ]
        let runner: String?
        switch phase {
        case "analysis": runner = "registry.analysis"
        case "frames": runner = "host.frames_runner"
        case "render": runner = "host.render_runner"
        default: runner = nil
        }
        let steps: [String]
        switch (phase, supportsModernHarness) {
        case ("analysis", _): steps = ["one_song_contract"]
        case ("frames", true): steps = ["prepare_frames_manifest"]
        case ("render", true): steps = ["prepare_final_render_manifest"]
        default: steps = []
        }
        return .init(
            artifact: artifact[phase]!,
            writer: writer[phase]!,
            runner: runner,
            gate: "registry.\(phase)",
            lineage: phase == "project_init" || !supportsModernHarness
                ? nil
                : "registry.\(phase)",
            deterministicSteps: steps
        )
    }

    private static func label(for phase: String) -> String {
        [
            "project_init": "Project Init",
            "analysis": "Audio Analysis",
            "brief": "Brief",
            "production_design": "Production Design",
            "treatment": "Treatment",
            "storyboard": "Storyboard",
            "bible": "Bible",
            "shotlist": "Shot List",
            "sanity": "Sanity Check",
            "frames": "Frames",
            "render": "Render",
        ][phase]!
    }
}

struct PreparedPhaseContractBundle: Sendable {
    let identity: PhaseContractBundleIdentity
    let manifest: PackPipelineManifest
    let hardSteps: HardStepManifest
    let resourceRoot: URL
    let historicalCompatibility: Bool
}

enum PhaseContractBundleLoader {
    static func prepare(
        identity: PhaseContractBundleIdentity,
        bundleURL: URL
    ) throws -> PreparedPhaseContractBundle {
        let manifest: PackPipelineManifest
        let declaredRoot: String
        let historicalCompatibility: Bool
        if identity.pipelineContractVersion == PackPipelineManifest.currentVersion {
            historicalCompatibility = false
            guard PackResourceLocator.validateRelativePath(identity.resourceRoot) else {
                throw PhaseContractError.malformed("NGVPackResourceRoot is missing or invalid")
            }
            declaredRoot = identity.resourceRoot
            let root = try PackResourceLocator.root(
                bundleURL: bundleURL,
                relativePath: declaredRoot
            )
            let manifestURL = try PackResourceLocator.file(
                PackPipelineManifest.resourceName,
                inside: root
            )
            do {
                manifest = try PackPipelineManifest.decode(Data(contentsOf: manifestURL))
            } catch let error as PhaseContractError {
                throw error
            } catch {
                throw PhaseContractError.malformed(error.localizedDescription)
            }
        } else if identity.pipelineContractVersion == 0 {
            historicalCompatibility = true
            let key = HistoricalPhaseContractCompatibility.Key(
                id: identity.id,
                version: identity.version,
                engineContract: identity.engineContract
            )
            guard let historical = HistoricalPhaseContractCompatibility.manifest(for: key),
                  let root = HistoricalPhaseContractCompatibility.resourceRoot(for: key) else {
                throw PhaseContractError.unsupportedHistoricalPack(
                    id: identity.id,
                    version: identity.version,
                    engineContract: identity.engineContract
                )
            }
            manifest = historical
            declaredRoot = root
        } else {
            throw PhaseContractError.malformed(
                "unsupported NGVPipelineContractVersion \(identity.pipelineContractVersion)"
            )
        }

        let resourceRoot = try PackResourceLocator.root(
            bundleURL: bundleURL,
            relativePath: declaredRoot
        )
        guard manifest.packID == identity.id,
              manifest.resourceRoot == declaredRoot else {
            throw PhaseContractError.malformed(
                "pipeline contract identity or resource root does not match Info.plist"
            )
        }
        let hardSteps = try loadHardSteps(resourceRoot: resourceRoot)
        try PhaseContractResolver.validateStructure(
            manifest,
            resourceRoot: resourceRoot,
            hardSteps: hardSteps,
            allowsMissingLineage: historicalCompatibility && identity.engineContract == 2
        )
        return PreparedPhaseContractBundle(
            identity: identity,
            manifest: manifest,
            hardSteps: hardSteps,
            resourceRoot: resourceRoot,
            historicalCompatibility: historicalCompatibility
        )
    }

    static func prepareDirect(pack: any Pack) throws -> PreparedPhaseContractBundle {
        guard let badgeURL = pack.manifest.badgeURL else {
            throw PhaseContractError.unavailable(pack.name)
        }
        let resourceRoot = badgeURL.deletingLastPathComponent()
        let manifestURL = try PackResourceLocator.file(
            PackPipelineManifest.resourceName,
            inside: resourceRoot
        )
        let manifest = try PackPipelineManifest.decode(Data(contentsOf: manifestURL))
        guard manifest.packID == pack.name,
              PackResourceLocator.validateRelativePath(manifest.resourceRoot),
              resourceRoot.standardizedFileURL.path.hasSuffix("/\(manifest.resourceRoot)") else {
            throw PhaseContractError.unavailable(pack.name)
        }
        let hardSteps = try loadHardSteps(resourceRoot: resourceRoot)
        try PhaseContractResolver.validateStructure(
            manifest,
            resourceRoot: resourceRoot,
            hardSteps: hardSteps
        )
        return PreparedPhaseContractBundle(
            identity: .init(
                id: pack.name,
                version: pack.version,
                engineContract: EngineContract.current,
                pipelineContractVersion: PackPipelineManifest.currentVersion,
                resourceRoot: manifest.resourceRoot
            ),
            manifest: manifest,
            hardSteps: hardSteps,
            resourceRoot: resourceRoot,
            historicalCompatibility: false
        )
    }

    private static func loadHardSteps(resourceRoot: URL) throws -> HardStepManifest {
        let url = try PackResourceLocator.file(
            HardStepManifest.resourceName,
            inside: resourceRoot
        )
        do {
            return try HardStepManifest.decode(Data(contentsOf: url))
        } catch let error as PhaseContractError {
            throw error
        } catch {
            throw PhaseContractError.malformed(
                "\(HardStepManifest.resourceName) is invalid: \(error.localizedDescription)"
            )
        }
    }
}

enum PhaseContractStore {
    private final class Store: @unchecked Sendable {
        private struct Entry {
            let contract: ResolvedPhaseContract
            let packRevision: UInt64
        }

        private let lock = NSLock()
        private var contracts: [String: Entry] = [:]

        func register(_ contract: ResolvedPhaseContract, packRevision: UInt64) {
            lock.lock()
            contracts[contract.packID] = Entry(
                contract: contract,
                packRevision: packRevision
            )
            lock.unlock()
        }

        func contract(_ packID: String, packRevision: UInt64) -> ResolvedPhaseContract? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = contracts[packID], entry.packRevision == packRevision else {
                return nil
            }
            return entry.contract
        }

        func all() -> [ResolvedPhaseContract] {
            lock.lock()
            defer { lock.unlock() }
            return contracts.values.map(\.contract)
        }

        func removeAll() {
            lock.lock()
            contracts.removeAll()
            lock.unlock()
        }

        func remove(_ packID: String) {
            lock.lock()
            contracts.removeValue(forKey: packID)
            lock.unlock()
        }
    }

    private static let store = Store()

    static func register(_ contract: ResolvedPhaseContract) {
        store.register(
            contract,
            packRevision: PackCatalog.revision(named: contract.packID)
        )
    }

    static func contract(packID: String) -> ResolvedPhaseContract? {
        store.contract(
            packID,
            packRevision: PackCatalog.revision(named: packID)
        )
    }

    static func all() -> [ResolvedPhaseContract] {
        store.all().filter {
            store.contract(
                $0.packID,
                packRevision: PackCatalog.revision(named: $0.packID)
            ) != nil
        }
    }

    static func remove(packID: String) { store.remove(packID) }

    static func removeAllForTesting() { store.removeAll() }
}

enum PhaseContractRuntime {
    static func contract(activePack: String?) throws -> ResolvedPhaseContract? {
        guard let activePack else { return nil }
        guard let pack = PackCatalog.pack(named: activePack) else {
            PhaseContractStore.remove(packID: activePack)
            throw PhaseContractError.unavailable(activePack)
        }
        if let loaded = PhaseContractStore.contract(packID: activePack),
           loaded.packVersion == pack.version,
           FileManager.default.fileExists(atPath: loaded.resourceRoot.path) {
            return loaded
        }
        PhaseContractStore.remove(packID: activePack)
        let prepared = try PhaseContractBundleLoader.prepareDirect(pack: pack)
        let registry = PackCatalog.registry(activePack: activePack)
        let resolved = try PhaseContractResolver.resolve(
            manifest: prepared.manifest,
            packVersion: prepared.identity.version,
            engineContract: prepared.identity.engineContract,
            resourceRoot: prepared.resourceRoot,
            hardSteps: prepared.hardSteps,
            registry: registry,
            historicalCompatibility: prepared.historicalCompatibility
        )
        try validateLockedMusicvideoIfNeeded(resolved, registry: registry)
        PhaseContractStore.register(resolved)
        return resolved
    }

    static func order(activePack: String?) throws -> [String] {
        try contract(activePack: activePack)?.order ?? coreGatePhases
    }

    static func gateRequirement(
        activePack: String?,
        phase: String,
        registry: EngineRegistry
    ) throws -> EngineRegistry.GateRequirement? {
        guard let resolved = try contract(activePack: activePack),
              let declaration = resolved.phase(phase)?.declaration else {
            return registry.gateRequirements[phase]
        }
        if declaration.selectors.gate == PhaseContractHostRegistry.genericSelector {
            return { dataRoot in
                try GenericPhaseExtensionWriter.requireCurrent(
                    contract: resolved,
                    phase: phase,
                    dataRoot: dataRoot
                )
            }
        }
        return registry.gateRequirements[phase]
    }

    static func lineageProvider(
        activePack: String?,
        phase: String,
        registry: EngineRegistry
    ) throws -> EngineRegistry.PhaseLineageProvider? {
        guard let resolved = try contract(activePack: activePack),
              let declaration = resolved.phase(phase)?.declaration else {
            return registry.phaseLineageProviders[phase]
        }
        if declaration.selectors.lineage == PhaseContractHostRegistry.genericSelector {
            return { dataRoot in
                try GenericPhaseExtensionWriter.lineageSnapshot(
                    contract: resolved,
                    phase: phase,
                    dataRoot: dataRoot
                )
            }
        }
        guard declaration.selectors.lineage != nil else { return nil }
        return registry.phaseLineageProviders[phase]
    }

    static func displayLabel(for phase: String) -> String? {
        let matches = PhaseContractStore.all().compactMap {
            guard let pack = PackCatalog.pack(named: $0.packID),
                  pack.version == $0.packVersion else { return nil }
            return $0.phase(phase)?.declaration.display?.label
        }
        return Set(matches).count == 1 ? matches.first : nil
    }

    static func validateLockedMusicvideoIfNeeded(
        _ resolved: ResolvedPhaseContract,
        registry: EngineRegistry
    ) throws {
        guard resolved.packID == "musicvideo" else { return }
        let historicalKey = HistoricalPhaseContractCompatibility.Key(
            id: resolved.packID,
            version: resolved.packVersion,
            engineContract: resolved.engineContract
        )
        if resolved.historicalCompatibility,
           let expectedIntake = HistoricalPhaseContractCompatibility.intake(for: historicalKey) {
            guard resolved.order == PipelineAgentContract.musicvideoPhases,
                  resolved.hardSteps.declaredPhases == expectedIntake.map(\.phase),
                  expectedIntake.allSatisfy({ expectation in
                      resolved.hardSteps.steps(for: expectation.phase).map(\.kind)
                        == expectation.kinds
                  }) else {
                throw PhaseContractError.registryMismatch(
                    "historical Music Video startup or phase order differs from its exact compatibility contract"
                )
            }
            return
        }
        let failures = PipelineAgentContract.failures(
            registry: registry,
            manifest: resolved.hardSteps,
            phaseDocument: { name in
                let relative = "phases/\(name).md"
                guard let url = try? PackResourceLocator.file(
                    relative,
                    inside: resolved.resourceRoot
                ) else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }
        )
        guard failures.isEmpty, resolved.order == PipelineAgentContract.musicvideoPhases else {
            throw PhaseContractError.registryMismatch(
                failures.first ?? "Music Video phase order differs from the locked contract"
            )
        }
        for phase in PipelineAgentContract.musicvideoPhases {
            guard let declaration = resolved.phase(phase) else {
                throw PhaseContractError.registryMismatch(
                    "Music Video is missing phase \(phase)"
                )
            }
            let expectedPhaseBound = PipelineAgentContract.executableTools[phase] ?? []
            let expectedSupporting = PipelineAgentContract.currentPhaseCapabilities[phase] ?? []
            guard declaration.phaseBoundCapabilities == expectedPhaseBound,
                  declaration.supportingCapabilities == expectedSupporting else {
                throw PhaseContractError.registryMismatch(
                    "Music Video capabilities differ for \(phase)"
                )
            }
        }
        let declaredPostPipeline = Set(
            resolved.manifest.postPipelineCapabilities.compactMap { ToolName(rawValue: $0) }
        )
        guard declaredPostPipeline == PipelineAgentContract.postPipelineUtilityCapabilities else {
            throw PhaseContractError.registryMismatch(
                "Music Video post-pipeline capabilities differ from the locked contract"
            )
        }
    }
}
