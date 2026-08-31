import Foundation

struct PackPipelineManifest: Sendable, Equatable, Decodable {
    static let currentSchema = "pipeline-contract/v1"
    static let currentVersion = 1
    static let resourceName = "pipeline-contract.json"

    let schema: String
    let contractID: String
    let packID: String
    let resourceRoot: String
    let hardStepsManifestID: String
    let display: Display
    let policyIDs: [String]
    let postPipelineCapabilities: [String]
    let phases: [Phase]

    init(
        schema: String = currentSchema,
        contractID: String,
        packID: String,
        resourceRoot: String,
        hardStepsManifestID: String,
        display: Display,
        policyIDs: [String] = [],
        postPipelineCapabilities: [String] = [],
        phases: [Phase]
    ) {
        self.schema = schema
        self.contractID = contractID
        self.packID = packID
        self.resourceRoot = resourceRoot
        self.hardStepsManifestID = hardStepsManifestID
        self.display = display
        self.policyIDs = policyIDs
        self.postPipelineCapabilities = postPipelineCapabilities
        self.phases = phases
    }

    struct Display: Sendable, Equatable, Decodable {
        let title: String
        let localizationTable: String?

        init(title: String, localizationTable: String? = nil) {
            self.title = title
            self.localizationTable = localizationTable
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case title
            case localizationTable
        }

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self, context: "display")
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try values.decode(String.self, forKey: .title)
            localizationTable = try values.decodeIfPresent(String.self, forKey: .localizationTable)
        }
    }

    struct Phase: Sendable, Equatable, Decodable {
        let id: String
        let executionIndex: Int
        let dependencies: [String]
        let roles: [Role]
        let selectors: Selectors
        let capabilities: Capabilities
        let instructions: String
        let display: PhaseDisplayMetadata?
        let policyIDs: [String]
        let extensionArtifact: ExtensionArtifact?

        init(
            id: String,
            executionIndex: Int,
            dependencies: [String],
            roles: [Role],
            selectors: Selectors,
            capabilities: Capabilities,
            instructions: String,
            display: PhaseDisplayMetadata? = nil,
            policyIDs: [String] = [],
            extensionArtifact: ExtensionArtifact? = nil
        ) {
            self.id = id
            self.executionIndex = executionIndex
            self.dependencies = dependencies
            self.roles = roles
            self.selectors = selectors
            self.capabilities = capabilities
            self.instructions = instructions
            self.display = display
            self.policyIDs = policyIDs
            self.extensionArtifact = extensionArtifact
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id
            case executionIndex
            case dependencies
            case roles
            case selectors
            case capabilities
            case instructions
            case display
            case policyIDs
            case extensionArtifact
        }

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self, context: "phase")
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            executionIndex = try values.decode(Int.self, forKey: .executionIndex)
            dependencies = try values.decode([String].self, forKey: .dependencies)
            roles = try values.decode([Role].self, forKey: .roles)
            selectors = try values.decode(Selectors.self, forKey: .selectors)
            capabilities = try values.decode(Capabilities.self, forKey: .capabilities)
            instructions = try values.decode(String.self, forKey: .instructions)
            display = try values.decodeIfPresent(PhaseDisplayMetadata.self, forKey: .display)
            policyIDs = try values.decodeIfPresent([String].self, forKey: .policyIDs) ?? []
            extensionArtifact = try values.decodeIfPresent(
                ExtensionArtifact.self,
                forKey: .extensionArtifact
            )
        }
    }

    enum Role: String, Sendable, Equatable, Decodable, CaseIterable {
        case intake
        case deterministicRunner = "deterministic_runner"
        case canonicalWriter = "canonical_writer"
        case reviewGate = "review_gate"
        case utility
    }

    struct Selectors: Sendable, Equatable, Decodable {
        let artifact: String
        let writer: String
        let runner: String?
        let gate: String
        let lineage: String?
        let deterministicSteps: [String]

        init(
            artifact: String,
            writer: String,
            runner: String? = nil,
            gate: String,
            lineage: String? = nil,
            deterministicSteps: [String] = []
        ) {
            self.artifact = artifact
            self.writer = writer
            self.runner = runner
            self.gate = gate
            self.lineage = lineage
            self.deterministicSteps = deterministicSteps
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case artifact
            case writer
            case runner
            case gate
            case lineage
            case deterministicSteps
        }

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self, context: "phase selectors")
            let values = try decoder.container(keyedBy: CodingKeys.self)
            artifact = try values.decode(String.self, forKey: .artifact)
            writer = try values.decode(String.self, forKey: .writer)
            runner = try values.decodeIfPresent(String.self, forKey: .runner)
            gate = try values.decode(String.self, forKey: .gate)
            lineage = try values.decodeIfPresent(String.self, forKey: .lineage)
            deterministicSteps = try values.decodeIfPresent(
                [String].self,
                forKey: .deterministicSteps
            ) ?? []
        }
    }

    struct Capabilities: Sendable, Equatable, Decodable {
        let phaseBound: [String]
        let supporting: [String]

        init(phaseBound: [String], supporting: [String]) {
            self.phaseBound = phaseBound
            self.supporting = supporting
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case phaseBound
            case supporting
        }

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self, context: "phase capabilities")
            let values = try decoder.container(keyedBy: CodingKeys.self)
            phaseBound = try values.decode([String].self, forKey: .phaseBound)
            supporting = try values.decode([String].self, forKey: .supporting)
        }
    }

    struct PhaseDisplayMetadata: Sendable, Equatable, Decodable {
        let label: String
        let localizationKey: String?

        init(label: String, localizationKey: String? = nil) {
            self.label = label
            self.localizationKey = localizationKey
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case label
            case localizationKey
        }

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self, context: "phase display")
            let values = try decoder.container(keyedBy: CodingKeys.self)
            label = try values.decode(String.self, forKey: .label)
            localizationKey = try values.decodeIfPresent(String.self, forKey: .localizationKey)
        }
    }

    struct ExtensionArtifact: Sendable, Equatable, Decodable {
        let relativePath: String
        let schemaResource: String

        init(relativePath: String, schemaResource: String) {
            self.relativePath = relativePath
            self.schemaResource = schemaResource
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case relativePath
            case schemaResource
        }

        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(CodingKeys.self, context: "extension artifact")
            let values = try decoder.container(keyedBy: CodingKeys.self)
            relativePath = try values.decode(String.self, forKey: .relativePath)
            schemaResource = try values.decode(String.self, forKey: .schemaResource)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case contractID
        case packID
        case resourceRoot
        case hardStepsManifestID
        case display
        case policyIDs
        case postPipelineCapabilities
        case phases
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self, context: "pipeline contract")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema)
        contractID = try values.decode(String.self, forKey: .contractID)
        packID = try values.decode(String.self, forKey: .packID)
        resourceRoot = try values.decode(String.self, forKey: .resourceRoot)
        hardStepsManifestID = try values.decode(String.self, forKey: .hardStepsManifestID)
        display = try values.decode(Display.self, forKey: .display)
        policyIDs = try values.decodeIfPresent([String].self, forKey: .policyIDs) ?? []
        postPipelineCapabilities = try values.decodeIfPresent(
            [String].self,
            forKey: .postPipelineCapabilities
        ) ?? []
        phases = try values.decode([Phase].self, forKey: .phases)
    }

    static func decode(_ data: Data) throws -> PackPipelineManifest {
        try JSONDecoder().decode(PackPipelineManifest.self, from: data)
    }
}

private struct PhaseContractAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension Decoder {
    func rejectUnknownKeys<Key: CodingKey & CaseIterable>(
        _ keyType: Key.Type,
        context: String
    ) throws where Key.AllCases: Collection {
        let values = try container(keyedBy: PhaseContractAnyCodingKey.self)
        let allowed = Set(Key.allCases.map(\.stringValue))
        let unknown = values.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: codingPath,
                    debugDescription: "Unknown field(s) in \(context): \(unknown.joined(separator: ", "))"
                )
            )
        }
    }
}
