import CryptoKit
import CoreFoundation
import Foundation
import NexGenEngine

enum HostPhaseIntakeLineage {
    static func snapshot(
        steps: [HardStep],
        dataRoot: URL
    ) throws -> PhaseLineageSnapshot {
        let kinds = Set(steps.map(\.kind))
        let ledger = IntakeLedger.load(dataRoot: dataRoot)
        return PhaseLineageSnapshot(
            inputFingerprint: try fingerprint(
                markers: steps.map {
                    "\($0.id):\($0.kind.rawValue):"
                        + (ledger.isDeclined($0.id) ? "declined" : "accepted_or_pending")
                },
                files: projectMetadataFiles(dataRoot: dataRoot),
                dataRoot: dataRoot
            ),
            artifactFingerprint: try fingerprint(
                markers: kinds.map(\.rawValue).sorted(),
                files: try intakeFiles(kinds: kinds, dataRoot: dataRoot),
                dataRoot: dataRoot
            )
        )
    }

    private static func projectMetadataFiles(dataRoot: URL) -> [URL] {
        [
            dataRoot.appendingPathComponent(PipelineLayout.projectFile),
        ]
    }

    private static func intakeFiles(
        kinds: Set<HardStep.Kind>,
        dataRoot: URL
    ) throws -> [URL] {
        var files: [URL] = []
        if kinds.contains(.song) {
            files += try regularFiles(
                at: "audio",
                recursive: false,
                extensions: AudioProjectLayout.audioExtensions,
                dataRoot: dataRoot
            )
        }
        if kinds.contains(.lyrics) {
            files.append(dataRoot.appendingPathComponent("lyrics/lyrics.txt"))
        }
        if kinds.contains(.script) {
            files.append(dataRoot.appendingPathComponent("import/script.md"))
        }
        if kinds.contains(.character) {
            files += try regularFiles(
                at: "import/characters",
                recursive: true,
                dataRoot: dataRoot
            )
        }
        if kinds.contains(.location) {
            files += try regularFiles(
                at: "import/locations",
                recursive: true,
                dataRoot: dataRoot
            )
        }
        if kinds.contains(.style) {
            files += try regularFiles(
                at: "import",
                recursive: false,
                extensions: IntakeSatisfaction.styleReferenceExtensions,
                dataRoot: dataRoot
            )
        }
        return Array(Set(files.map(\.standardizedFileURL))).sorted {
            $0.path < $1.path
        }
    }

    private static func regularFiles(
        at relativeDirectory: String,
        recursive: Bool,
        extensions: Set<String>? = nil,
        dataRoot: URL
    ) throws -> [URL] {
        let directory = dataRoot.appendingPathComponent(
            relativeDirectory,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw GateBlocked("Pipeline intake input \(relativeDirectory) is not a real directory.")
        }
        var result: [URL] = []
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw GateBlocked("Pipeline intake inputs must not contain symbolic links.")
            }
            if values.isDirectory == true, recursive {
                let child = relativeDirectory + "/" + entry.lastPathComponent
                result += try regularFiles(
                    at: child,
                    recursive: true,
                    extensions: extensions,
                    dataRoot: dataRoot
                )
            } else if values.isRegularFile == true,
                      extensions?.contains(entry.pathExtension.lowercased()) ?? true {
                result.append(entry)
            }
        }
        return result
    }

    private static func fingerprint(
        markers: [String],
        files: [URL],
        dataRoot: URL
    ) throws -> String {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        var hasher = SHA256()
        for marker in markers.sorted() {
            hasher.update(data: Data("marker:\(marker)\u{0}".utf8))
        }
        for file in files.sorted(by: { $0.path < $1.path }) {
            let standardized = file.standardizedFileURL
            let relative = standardized.path.hasPrefix(root.path + "/")
                ? String(standardized.path.dropFirst(root.path.count + 1))
                : standardized.lastPathComponent
            guard FileManager.default.fileExists(atPath: standardized.path) else {
                hasher.update(data: Data("missing:\(relative)\u{0}".utf8))
                continue
            }
            let values = try standardized.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard standardized.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw GateBlocked("Pipeline intake input \(relative) is not a real project file.")
            }
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: standardized))
            hasher.update(data: Data([0xff]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct PhaseExtensionSchema: Sendable {
    private let root: [String: AnySendable]

    static func load(from url: URL) throws -> PhaseExtensionSchema {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw PhaseContractError.malformed("extension schema must be a JSON object")
        }
        let wrapped = try AnySendable.wrap(dictionary)
        guard case .object(let root) = wrapped else {
            throw PhaseContractError.malformed("extension schema must be a JSON object")
        }
        try validateSchemaNode(root, path: "schema", isRoot: true)
        return PhaseExtensionSchema(root: root)
    }

    func validate(_ value: Any) throws {
        try Self.validateValue(
            AnySendable.wrap(value),
            against: root,
            path: "payload"
        )
    }

    private static let supportedKeywords: Set<String> = [
        "$id", "$schema", "additionalProperties", "description", "enum", "items",
        "maxItems", "maxLength", "minItems", "minLength", "properties", "required",
        "title", "type",
    ]

    private static func validateSchemaNode(
        _ node: [String: AnySendable],
        path: String,
        isRoot: Bool = false
    ) throws {
        let unknown = Set(node.keys).subtracting(supportedKeywords)
        guard unknown.isEmpty else {
            throw PhaseContractError.malformed(
                "unsupported extension-schema keyword(s) at \(path): \(unknown.sorted().joined(separator: ", "))"
            )
        }
        guard case .string(let type)? = node["type"],
              ["array", "boolean", "integer", "number", "object", "string"].contains(type) else {
            throw PhaseContractError.malformed("\(path) must declare one supported type")
        }
        if isRoot, type != "object" {
            throw PhaseContractError.malformed("extension schema root must have type object")
        }
        for key in ["$id", "$schema", "description", "title"] {
            if let value = node[key],
               value.nonemptyString == nil {
                throw PhaseContractError.malformed("\(path).\(key) must be a non-empty string")
            }
        }
        if type == "object" {
            guard node["additionalProperties"] == .bool(false),
                  case .object(let properties)? = node["properties"] else {
                throw PhaseContractError.malformed(
                    "\(path) object must declare properties and additionalProperties false"
                )
            }
            for (name, child) in properties {
                guard validPropertyName(name), case .object(let childNode) = child else {
                    throw PhaseContractError.malformed("invalid property schema at \(path).\(name)")
                }
                try validateSchemaNode(childNode, path: "\(path).\(name)")
            }
            let required = try stringArray(node["required"], path: "\(path).required")
            guard Set(required).isSubset(of: Set(properties.keys)),
                  Set(required).count == required.count else {
                throw PhaseContractError.malformed("\(path).required is invalid")
            }
        } else if node["properties"] != nil || node["required"] != nil
                    || node["additionalProperties"] != nil {
            throw PhaseContractError.malformed(
                "\(path) uses object-only schema keywords for type \(type)"
            )
        }
        if type == "array" {
            guard case .object(let items)? = node["items"] else {
                throw PhaseContractError.malformed("\(path) array must declare one items schema")
            }
            try validateSchemaNode(items, path: "\(path)[]")
            try validateBounds(node, minimum: "minItems", maximum: "maxItems", path: path)
        } else if node["items"] != nil || node["minItems"] != nil || node["maxItems"] != nil {
            throw PhaseContractError.malformed(
                "\(path) uses array-only schema keywords for type \(type)"
            )
        }
        if let values = node["enum"] {
            guard case .array(let enumValues) = values, !enumValues.isEmpty else {
                throw PhaseContractError.malformed("\(path).enum must be a non-empty array")
            }
            guard enumValues.indices.allSatisfy({ index in
                !enumValues[..<index].contains(enumValues[index])
            }), enumValues.allSatisfy({ valueMatchesType($0, type: type) }) else {
                throw PhaseContractError.malformed(
                    "\(path).enum values must be unique and match type \(type)"
                )
            }
        }
        if type == "string" {
            try validateBounds(node, minimum: "minLength", maximum: "maxLength", path: path)
        } else if node["minLength"] != nil || node["maxLength"] != nil {
            throw PhaseContractError.malformed(
                "\(path) uses string-only schema keywords for type \(type)"
            )
        }
    }

    private static func validateBounds(
        _ node: [String: AnySendable],
        minimum: String,
        maximum: String,
        path: String
    ) throws {
        let lower = node[minimum]?.nonnegativeInteger
        let upper = node[maximum]?.nonnegativeInteger
        if node[minimum] != nil, lower == nil {
            throw PhaseContractError.malformed("\(path).\(minimum) must be a non-negative integer")
        }
        if node[maximum] != nil, upper == nil {
            throw PhaseContractError.malformed("\(path).\(maximum) must be a non-negative integer")
        }
        if let lower, let upper, lower > upper {
            throw PhaseContractError.malformed("\(path).\(minimum) exceeds \(maximum)")
        }
    }

    private static func valueMatchesType(_ value: AnySendable, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string),
             ("boolean", .bool), ("integer", .integer), ("number", .integer),
             ("number", .number):
            return true
        default:
            return false
        }
    }

    private static func validateValue(
        _ value: AnySendable,
        against schema: [String: AnySendable],
        path: String
    ) throws {
        guard case .string(let type) = schema["type"] else {
            throw PhaseContractError.malformed("schema type is unavailable at \(path)")
        }
        guard valueMatchesType(value, type: type) else {
            throw ToolError("\(path) must be \(type).")
        }

        if case .array(let allowed)? = schema["enum"], !allowed.contains(value) {
            throw ToolError("\(path) is not one of the schema's allowed values.")
        }
        switch value {
        case .object(let object):
            guard case .object(let properties) = schema["properties"] else {
                throw PhaseContractError.malformed("object schema is incomplete at \(path)")
            }
            let unknown = Set(object.keys).subtracting(properties.keys)
            guard unknown.isEmpty else {
                throw ToolError("\(path) contains unknown field(s): \(unknown.sorted().joined(separator: ", ")).")
            }
            let required = try stringArray(schema["required"], path: "\(path).required")
            let missing = Set(required).subtracting(object.keys)
            guard missing.isEmpty else {
                throw ToolError("\(path) is missing required field(s): \(missing.sorted().joined(separator: ", ")).")
            }
            for (name, child) in object {
                guard case .object(let childSchema)? = properties[name] else { continue }
                try validateValue(child, against: childSchema, path: "\(path).\(name)")
            }
        case .array(let values):
            if let minimum = schema["minItems"]?.nonnegativeInteger, values.count < minimum {
                throw ToolError("\(path) requires at least \(minimum) item(s).")
            }
            if let maximum = schema["maxItems"]?.nonnegativeInteger, values.count > maximum {
                throw ToolError("\(path) allows at most \(maximum) item(s).")
            }
            guard case .object(let itemSchema) = schema["items"] else {
                throw PhaseContractError.malformed("array schema is incomplete at \(path)")
            }
            for (index, child) in values.enumerated() {
                try validateValue(child, against: itemSchema, path: "\(path)[\(index)]")
            }
        case .string(let string):
            if let minimum = schema["minLength"]?.nonnegativeInteger, string.count < minimum {
                throw ToolError("\(path) is shorter than \(minimum) characters.")
            }
            if let maximum = schema["maxLength"]?.nonnegativeInteger, string.count > maximum {
                throw ToolError("\(path) is longer than \(maximum) characters.")
            }
        default:
            break
        }
    }

    private static func stringArray(
        _ value: AnySendable?,
        path: String
    ) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let values) = value else {
            throw PhaseContractError.malformed("\(path) must be an array of strings")
        }
        return try values.map {
            guard case .string(let string) = $0 else {
                throw PhaseContractError.malformed("\(path) must contain only strings")
            }
            return string
        }
    }

    private static func validPropertyName(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(".") && !value.contains("/")
    }
}

private enum AnySendable: Sendable, Equatable {
    case array([AnySendable])
    case bool(Bool)
    case integer(Int64)
    case null
    case number(Double)
    case object([String: AnySendable])
    case string(String)

    static func wrap(_ value: Any) throws -> AnySendable {
        switch value {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let double = value.doubleValue
            if double.rounded() == double,
               double >= Double(Int64.min), double <= Double(Int64.max) {
                return .integer(value.int64Value)
            }
            return .number(double)
        case let value as [Any]:
            return .array(try value.map(wrap))
        case let value as [String: Any]:
            return .object(try value.mapValues(wrap))
        default:
            throw ToolError("Payload contains a value that JSON cannot represent.")
        }
    }

    var nonnegativeInteger: Int? {
        guard case .integer(let value) = self,
              value >= 0, value <= Int64(Int.max) else { return nil }
        return Int(value)
    }

    var nonemptyString: String? {
        guard case .string(let value) = self,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

enum GenericPhaseExtensionWriter {
    static func write(
        contract: ResolvedPhaseContract,
        phase: String,
        payload: [String: Any],
        dataRoot: URL
    ) throws -> URL {
        let declaration = try declaration(contract: contract, phase: phase)
        let extensionArtifact = declaration.extensionArtifact!
        let schemaURL = try PackResourceLocator.file(
            extensionArtifact.schemaResource,
            inside: contract.resourceRoot
        )
        try PhaseExtensionSchema.load(from: schemaURL).validate(payload)
        let destination = try projectFile(
            extensionArtifact.relativePath,
            dataRoot: dataRoot
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        data.append(0x0a)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func requireCurrent(
        contract: ResolvedPhaseContract,
        phase: String,
        dataRoot: URL
    ) throws {
        let declaration = try declaration(contract: contract, phase: phase)
        let extensionArtifact = declaration.extensionArtifact!
        let artifactURL = try projectFile(extensionArtifact.relativePath, dataRoot: dataRoot)
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            throw GateBlocked(
                "Can't approve \"\(phase)\": its canonical extension artifact is missing."
            )
        }
        let schemaURL = try PackResourceLocator.file(
            extensionArtifact.schemaResource,
            inside: contract.resourceRoot
        )
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: artifactURL))
        try PhaseExtensionSchema.load(from: schemaURL).validate(object)
        try PipelineLineageStore.requireCurrent(
            phase: phase,
            snapshot: try lineageSnapshot(
                contract: contract,
                phase: phase,
                dataRoot: dataRoot
            ),
            dataRoot: dataRoot
        )
    }

    static func lineageSnapshot(
        contract: ResolvedPhaseContract,
        phase: String,
        dataRoot: URL
    ) throws -> PhaseLineageSnapshot {
        let declaration = try declaration(contract: contract, phase: phase)
        let artifactURL = try projectFile(
            declaration.extensionArtifact!.relativePath,
            dataRoot: dataRoot
        )
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            throw GateBlocked("The \(phase) extension artifact is missing.")
        }
        return PhaseLineageSnapshot(
            inputFingerprint: try cumulativeInputFingerprint(
                contract: contract,
                phase: phase,
                dataRoot: dataRoot
            ),
            artifactFingerprint: try FileDigest.sha256(of: artifactURL)
        )
    }

    private static func declaration(
        contract: ResolvedPhaseContract,
        phase: String
    ) throws -> PackPipelineManifest.Phase {
        guard let declaration = contract.phase(phase)?.declaration,
              declaration.selectors.writer == PhaseContractHostRegistry.genericSelector,
              declaration.extensionArtifact != nil else {
            throw ToolError("The \(phase) phase has no generic host writer.")
        }
        return declaration
    }

    private static func cumulativeInputFingerprint(
        contract: ResolvedPhaseContract,
        phase: String,
        dataRoot: URL
    ) throws -> String {
        guard let phaseIndex = contract.order.firstIndex(of: phase) else {
            throw PhaseContractError.unknownPhase(phase)
        }
        var hasher = SHA256()
        let projectURL = dataRoot.appendingPathComponent(PipelineLayout.projectFile)
        try hashFile(projectURL, relativePath: PipelineLayout.projectFile, into: &hasher)
        for prior in contract.phases[..<phaseIndex] {
            let id = prior.declaration.id
            if let artifact = prior.declaration.extensionArtifact {
                let snapshot = try lineageSnapshot(
                    contract: contract,
                    phase: id,
                    dataRoot: dataRoot
                )
                try PipelineLineageStore.requireCurrent(
                    phase: id,
                    snapshot: snapshot,
                    dataRoot: dataRoot
                )
                let url = try projectFile(artifact.relativePath, dataRoot: dataRoot)
                try hashFile(url, relativePath: artifact.relativePath, into: &hasher)
            } else if let provider = liveNativeLineageProvider(
                contract: contract,
                phase: prior
            ) {
                let snapshot = try provider(dataRoot)
                if prior.nativeLineageRequiresRecord {
                    try PipelineLineageStore.requireCurrent(
                        phase: id,
                        snapshot: snapshot,
                        dataRoot: dataRoot
                    )
                }
                hasher.update(data: Data("lineage:\(id)\u{0}".utf8))
                hasher.update(data: Data(snapshot.inputFingerprint.utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: Data(snapshot.artifactFingerprint.utf8))
                hasher.update(data: Data([0xff]))
            } else {
                throw GateBlocked(
                    "The \(phase) phase cannot prove exact lineage for prior phase \(id)."
                )
            }
        }
        if contract.phase(phase)?.declaration.roles.contains(.intake) == true {
            let intake = try HostPhaseIntakeLineage.snapshot(
                steps: contract.hardSteps.steps(for: phase),
                dataRoot: dataRoot
            )
            hasher.update(data: Data("intake:\(phase)\u{0}".utf8))
            hasher.update(data: Data(intake.inputFingerprint.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(intake.artifactFingerprint.utf8))
            hasher.update(data: Data([0xff]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func liveNativeLineageProvider(
        contract: ResolvedPhaseContract,
        phase: ResolvedPhaseContract.Phase
    ) -> EngineRegistry.PhaseLineageProvider? {
        let id = phase.declaration.id
        if phase.declaration.selectors.lineage == "registry.\(id)",
           PackCatalog.pack(named: contract.packID) != nil {
            return PackCatalog.registry(activePack: contract.packID)
                .phaseLineageProviders[id]
        }
        return phase.nativeLineageProvider
    }

    private static func hashFile(
        _ url: URL,
        relativePath: String,
        into hasher: inout SHA256
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GateBlocked("Required lineage input \(relativePath) is missing.")
        }
        hasher.update(data: Data(relativePath.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: try Data(contentsOf: url))
        hasher.update(data: Data([0xff]))
    }

    private static func projectFile(_ relativePath: String, dataRoot: URL) throws -> URL {
        guard PackResourceLocator.validateRelativePath(relativePath) else {
            throw PhaseContractError.malformed("unsafe extension artifact path")
        }
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        var current = root
        let components = relativePath.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            current.appendPathComponent(component, isDirectory: true)
            if FileManager.default.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw PhaseContractError.malformed(
                        "extension artifact path traverses a non-directory or symbolic link"
                    )
                }
            }
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw PhaseContractError.malformed("extension artifact path escapes the project")
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let values = try candidate.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw PhaseContractError.malformed(
                    "extension artifact is not a regular project file"
                )
            }
        }
        return candidate
    }
}

extension ToolExecutor {
    func writePhaseExtensionTool(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) throws -> ToolResult {
        let dataRoot = try resolveDataRoot(args, editor: editor)
        guard let phase = args.string("phase")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phase.isEmpty,
              let payload = args["payload"] as? [String: Any] else {
            throw ToolError("phase and payload are required.")
        }
        let declaration = try mutationPackDeclaration(
            editor,
            dataRoot: dataRoot
        )
        let packName: String?
        do {
            packName = try ProjectPackGate.requireLiveMutation(
                projectURL: FrameInventory.projectHome(of: dataRoot),
                declaredPack: declaration.packName,
                declaredBinding: declaration.binding
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        guard let contract = try PhaseContractRuntime.contract(activePack: packName),
              contract.allowsPhaseBound(.writePhaseExtension, phase: phase) else {
            throw ToolError("The active workflow does not grant write_phase_extension to \(phase).")
        }
        do {
            _ = try ProjectPackGate.requireLiveMutation(
                projectURL: FrameInventory.projectHome(of: dataRoot),
                declaredPack: declaration.packName,
                declaredBinding: declaration.binding
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        let destination = try GenericPhaseExtensionWriter.write(
            contract: contract,
            phase: phase,
            payload: payload,
            dataRoot: dataRoot
        )
        let response: [String: Any] = [
            "phase": phase,
            "path": destination.path,
            "written": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        return .ok(String(decoding: data, as: UTF8.self))
    }
}
