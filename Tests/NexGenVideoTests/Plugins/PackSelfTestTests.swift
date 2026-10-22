import Foundation
import MusicvideoPlugin
import NexGenEngine
import Testing

@testable import NexGenVideo

@MainActor
@Suite("Pack self-test resources")
struct PackSelfTestTests {
    @MainActor
    private struct Fixture {
        let temporary: URL
        let resources: URL
        let record: InstalledPluginRecord
        let contract: ResolvedPhaseContract
        let registry: EngineRegistry

        func failure(contract: ResolvedPhaseContract? = nil) -> String? {
            PackSelfTest.requiredResourceFailure(
                record, contract: contract ?? self.contract, registry: registry
            )
        }
    }

    private func fixture() throws -> Fixture {
        let pack = MusicvideoPack()
        let prepared = try PhaseContractBundleLoader.prepareDirect(pack: pack)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-self-test-\(UUID().uuidString)", isDirectory: true)
        var ready = false
        defer { if !ready { try? FileManager.default.removeItem(at: temporary) } }
        let bundle = temporary.appendingPathComponent("musicvideo.ngvpack", isDirectory: true)
        let resources = bundle.appendingPathComponent(
            "Contents/Resources/NexGenVideo_MusicvideoPlugin.bundle/MusicvideoPack", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resources.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: prepared.resourceRoot, to: resources)
        let registry = EngineRegistry()
        pack.register(registry)
        let contract = try PhaseContractResolver.resolve(
            manifest: prepared.manifest,
            packVersion: pack.version,
            engineContract: EngineContract.current,
            resourceRoot: resources,
            hardSteps: prepared.hardSteps,
            registry: registry,
            projectSchema: "musicvideo/3.0.0"
        )
        let record = InstalledPluginRecord(
            id: "musicvideo", displayName: "Music Video", tagline: "", headline: "", benefit: "",
            version: "0.6.0", projectSchema: "musicvideo/3.0.0", migratesFrom: [],
            minAppVersion: "1.8.0", bundleURL: bundle, state: .loaded
        )
        ready = true
        return Fixture(temporary: temporary, resources: resources, record: record,
                       contract: contract, registry: registry)
    }

    @Test("the actual self-test checker accepts the shipped fourteen-phase Music Video contract")
    func currentProductionContractPasses() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        #expect(fixture.contract.order == [
            "project_init", "analysis", "brief", "production_design", "treatment", "script",
            "storyboard", "shot_planning", "bible", "shotlist", "sanity", "frames", "render_review", "render",
        ])
        #expect(fixture.failure() == nil)
    }

    enum StartupMutation: CaseIterable, Sendable {
        case missing, malformed, noSong, optionalSong, nonAudioSong, reversedStartup
        case requiredLyrics, analysisIntake, reversedCreative, requiredCreative, changedTitle

        var expectedFailure: String {
            switch self {
            case .missing, .malformed: "required hardsteps.json is missing or malformed"
            case .noSong, .optionalSong, .nonAudioSong: "project_init has no required audio song intake"
            case .reversedStartup: "project_init hard-step order is not exactly track, lyrics"
            case .requiredLyrics: "lyrics intake is not optional"
            case .analysisIntake: "analysis contains file intake"
            case .reversedCreative: "brief hard-step order is not existing story, characters, locations, style"
            case .requiredCreative: "creative-material intake is not fully optional"
            case .changedTitle: "resolved pipeline contract differs from the loaded pack or its intake resources"
            }
        }
    }

    @Test("self-test startup and exact intake binding fail closed", arguments: StartupMutation.allCases)
    func startupMutationIsRejected(_ mutation: StartupMutation) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let path = fixture.resources.appendingPathComponent("hardsteps.json")
        switch mutation {
        case .missing:
            try FileManager.default.removeItem(at: path)
        case .malformed:
            try Data("{not-json".utf8).write(to: path)
        default:
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            var phases = try #require(object["phases"] as? [[String: Any]])
            let startupIndex = try #require(phases.firstIndex { $0["phase"] as? String == "project_init" })
            let creativeIndex = try #require(phases.firstIndex { $0["phase"] as? String == "brief" })
            var startup = try #require(phases[startupIndex]["steps"] as? [[String: Any]])
            var creative = try #require(phases[creativeIndex]["steps"] as? [[String: Any]])
            switch mutation {
            case .noSong: startup.removeFirst()
            case .optionalSong: startup[0]["required"] = false
            case .nonAudioSong: startup[0]["accept"] = ["image"]
            case .reversedStartup: startup.swapAt(0, 1)
            case .requiredLyrics: startup[1]["required"] = true
            case .analysisIntake:
                var step = creative[0]
                step["id"] = "analysis.script"
                phases.append(["phase": "analysis", "steps": [step]])
            case .reversedCreative: creative.swapAt(0, 1)
            case .requiredCreative: creative[0]["required"] = true
            case .changedTitle: startup[0]["title"] = "Changed track title"
            case .missing, .malformed: break
            }
            phases[startupIndex]["steps"] = startup
            phases[creativeIndex]["steps"] = creative
            object["phases"] = phases
            try JSONSerialization.data(withJSONObject: object).write(to: path)
        }
        #expect(fixture.failure() == mutation.expectedFailure)
    }

    @Test("the self-test requires the actual resolved contract")
    func missingResolvedContractIsRejected() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        #expect(PackSelfTest.requiredResourceFailure(
            fixture.record, contract: nil, registry: fixture.registry
        ) == "resolved pipeline contract is unavailable after pack loading")
    }

    enum CoverMutation: CaseIterable, Equatable, Sendable {
        case missing, empty, noCompilePrompt, noGenerateImage, noListModels
        case approval, bash, render

        var requiredTool: String? {
            switch self {
            case .noCompilePrompt: "compile_prompt"
            case .noGenerateImage: "generate_image"
            case .noListModels: "list_models"
            default: nil
            }
        }

        var forbiddenOperation: String? {
            switch self {
            case .approval: "approve_gate"
            case .bash: "`Bash`"
            case .render: "record_render("
            default: nil
            }
        }
    }

    @Test("V2 still checks the packaged cover utility", arguments: CoverMutation.allCases)
    func coverMutationIsRejected(_ mutation: CoverMutation) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let path = fixture.resources.appendingPathComponent("phases/cover.md")
        let expected: String
        if mutation == .missing {
            try FileManager.default.removeItem(at: path)
            expected = "cover has no packaged post-pipeline utility document"
        } else if mutation == .empty {
            try Data().write(to: path)
            expected = "cover utility instructions don't name required tool compile_prompt"
        } else {
            var text = try String(contentsOf: path, encoding: .utf8)
            if let tool = mutation.requiredTool {
                text = text.replacingOccurrences(of: tool, with: "removed_tool")
                expected = "cover utility instructions don't name required tool \(tool)"
            } else {
                let operation = try #require(mutation.forbiddenOperation)
                text += "\n\(operation)\n"
                expected = "cover utility instructions contain forbidden pipeline operation \(operation)"
            }
            try text.write(to: path, atomically: true, encoding: .utf8)
        }
        #expect(fixture.failure() == expected)
    }

    @Test("self-test uses the V2 capability validator rather than accepting every loaded pack")
    func changedProductionCapabilitiesAreRejected() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let phases = fixture.contract.phases.map { phase in
            guard phase.declaration.id == "storyboard" else { return phase }
            return ResolvedPhaseContract.Phase(
                declaration: phase.declaration,
                phaseBoundCapabilities: phase.phaseBoundCapabilities,
                supportingCapabilities: phase.supportingCapabilities.union([.generateVideo]),
                nativeLineageProvider: phase.nativeLineageProvider,
                nativeArtifactProvider: phase.nativeArtifactProvider,
                nativeLineageRequiresRecord: phase.nativeLineageRequiresRecord
            )
        }
        let changed = replacing(fixture.contract, phases: phases)
        let failure = try #require(fixture.failure(contract: changed))
        #expect(failure.contains("storyboard capabilities differ from the supported production contract"))
    }

    @Test("another resource tree cannot replace the declared cover", arguments: [false, true])
    func unrelatedCoverCannotSatisfyTheLoadedContract(useSymlink: Bool) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let cover = fixture.resources.appendingPathComponent("phases/cover.md")
        let decoy = fixture.record.bundleURL.appendingPathComponent(
            "Contents/Resources/Other.bundle/MusicvideoPack/phases/cover.md"
        )
        try FileManager.default.createDirectory(
            at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: cover, to: decoy)
        try FileManager.default.removeItem(at: cover)
        if useSymlink {
            try FileManager.default.createSymbolicLink(at: cover, withDestinationURL: decoy)
        }
        #expect(fixture.failure() == "cover has no packaged post-pipeline utility document")
    }

    enum IdentityMutation: CaseIterable, Sendable {
        case packID, packVersion, projectSchema, missingSchema, engineContract, unknownContract
    }

    @Test("resolved identity cannot replace the loaded pack", arguments: IdentityMutation.allCases)
    func changedIdentityIsRejected(_ mutation: IdentityMutation) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let original = fixture.contract
        var packID = original.packID
        var version = original.packVersion
        var schema = original.projectSchema
        var engine = original.engineContract
        var manifest = original.manifest
        switch mutation {
        case .packID: packID = "other"
        case .packVersion: version = "0.7.0"
        case .projectSchema: schema = "musicvideo/4.0.0"
        case .missingSchema: schema = nil
        case .engineContract: engine += 1
        case .unknownContract:
            manifest = PackPipelineManifest(
                schema: manifest.schema, contractID: "musicvideo.pipeline.unknown", packID: manifest.packID,
                resourceRoot: manifest.resourceRoot, hardStepsManifestID: manifest.hardStepsManifestID,
                display: manifest.display, policyIDs: manifest.policyIDs,
                postPipelineCapabilities: manifest.postPipelineCapabilities, phases: manifest.phases
            )
        }
        let changed = ResolvedPhaseContract(
            packID: packID, packVersion: version, engineContract: engine,
            historicalCompatibility: original.historicalCompatibility, manifest: manifest,
            hardSteps: original.hardSteps, resourceRoot: original.resourceRoot,
            phases: original.phases, projectSchema: schema
        )
        let failure = try #require(fixture.failure(contract: changed))
        switch mutation {
        case .engineContract, .unknownContract:
            #expect(failure.contains("production workflow identity or phase set differs from its supported contract"))
        default:
            #expect(failure == "resolved pipeline contract differs from the loaded pack or its intake resources")
        }
    }

    private func replacing(
        _ original: ResolvedPhaseContract,
        phases: [ResolvedPhaseContract.Phase]
    ) -> ResolvedPhaseContract {
        ResolvedPhaseContract(
            packID: original.packID, packVersion: original.packVersion, engineContract: original.engineContract,
            historicalCompatibility: original.historicalCompatibility, manifest: original.manifest,
            hardSteps: original.hardSteps, resourceRoot: original.resourceRoot,
            phases: phases, projectSchema: original.projectSchema
        )
    }
}
