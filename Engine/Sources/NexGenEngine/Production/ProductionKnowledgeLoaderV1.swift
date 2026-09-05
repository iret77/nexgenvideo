import Foundation

public enum ProductionKnowledgeErrorV1: Error, Equatable, LocalizedError, Sendable {
    case resourceRootMissing
    case missingResource(String)
    case invalidJSON(path: String, reason: String)
    case invalidValue(path: String, reason: String)
    case digestMismatch(path: String, expected: String, actual: String)
    case conflictingResource(kind: String, id: String, versions: [String])

    public var errorDescription: String? {
        switch self {
        case .resourceRootMissing:
            return "Core production knowledge resources are missing."
        case .missingResource(let path):
            return "Core production knowledge resource is missing: \(path)"
        case .invalidJSON(let path, let reason):
            return "Invalid core production knowledge JSON at \(path): \(reason)"
        case .invalidValue(let path, let reason):
            return "Invalid core production knowledge value at \(path): \(reason)"
        case .digestMismatch(let path, let expected, let actual):
            return "Core production knowledge digest mismatch at \(path): expected \(expected), got \(actual)"
        case .conflictingResource(let kind, let id, let versions):
            return "Conflicting core \(kind) resource \(id): \(versions.joined(separator: ", "))"
        }
    }
}

public struct ProductionKnowledgeCatalogV1: Sendable, Equatable {
    public let profiles: [ProductionProfileDescriptorV1]
    public let libraries: [CreativeKnowledgeLibraryV1]

    public init(
        profiles: [ProductionProfileDescriptorV1],
        libraries: [CreativeKnowledgeLibraryV1]
    ) throws {
        try Self.rejectConflicts(
            profiles.map { ($0.id.rawValue, $0.version.rawValue) },
            kind: "profile"
        )
        try Self.rejectConflicts(
            libraries.map { ($0.id.rawValue, $0.version.rawValue) },
            kind: "library"
        )
        self.profiles = profiles.sorted {
            ($0.id.rawValue, $0.version.rawValue) < ($1.id.rawValue, $1.version.rawValue)
        }
        self.libraries = libraries.sorted {
            ($0.id.rawValue, $0.version.rawValue) < ($1.id.rawValue, $1.version.rawValue)
        }
    }

    public func profile(id: ProductionProfileDescriptorIDV1) -> ProductionProfileDescriptorV1? {
        profiles.first { $0.id == id }
    }

    public func library(id: CreativeKnowledgeLibraryIDV1) -> CreativeKnowledgeLibraryV1? {
        libraries.first { $0.id == id }
    }

    private static func rejectConflicts(_ resources: [(String, String)], kind: String) throws {
        let grouped = Dictionary(grouping: resources, by: { $0.0 })
        if let id = grouped.keys.sorted().first(where: {
            grouped[$0, default: []].count > 1
        }) {
            let values = grouped[id, default: []]
            throw ProductionKnowledgeErrorV1.conflictingResource(
                kind: kind,
                id: id,
                versions: values.map { $0.1 }.sorted()
            )
        }
    }
}

public struct ProductionKnowledgeLoaderV1: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func load() throws -> ProductionKnowledgeCatalogV1 {
        let manifestURL = rootURL.appendingPathComponent("manifest.json", isDirectory: false)
        let manifestData = try read(manifestURL, relativePath: "manifest.json")
        let manifest = try ProductionKnowledgeClosedSchemaV1.decodeManifest(
            manifestData,
            path: "manifest.json"
        )
        guard manifest.schemaVersion == "production-knowledge-manifest.v1" else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: "manifest.json.schemaVersion",
                reason: "unsupported schema \(manifest.schemaVersion)"
            )
        }
        try rejectManifestConflicts(manifest.resources)

        var profiles: [ProductionProfileDescriptorV1] = []
        var libraries: [CreativeKnowledgeLibraryV1] = []
        for resource in manifest.resources.sorted(by: resourceOrder) {
            let resourceURL = try resolvedResourceURL(resource.path)
            let data = try read(resourceURL, relativePath: resource.path)
            let actualDigest = try FileDigest.sha256(of: resourceURL)
            guard actualDigest == resource.sha256 else {
                throw ProductionKnowledgeErrorV1.digestMismatch(
                    path: resource.path,
                    expected: resource.sha256,
                    actual: actualDigest
                )
            }
            switch resource.kind {
            case .profile:
                let profile = try ProductionKnowledgeClosedSchemaV1.decodeProfile(
                    data,
                    path: resource.path
                )
                guard profile.id.rawValue == resource.id,
                      profile.version == resource.version else {
                    throw ProductionKnowledgeErrorV1.invalidValue(
                        path: resource.path,
                        reason: "manifest identity does not match resource identity"
                    )
                }
                profiles.append(profile)
            case .library:
                let library = try ProductionKnowledgeClosedSchemaV1.decodeLibrary(
                    data,
                    path: resource.path
                )
                guard library.id.rawValue == resource.id,
                      library.version == resource.version else {
                    throw ProductionKnowledgeErrorV1.invalidValue(
                        path: resource.path,
                        reason: "manifest identity does not match resource identity"
                    )
                }
                libraries.append(library)
            }
        }
        return try ProductionKnowledgeCatalogV1(profiles: profiles, libraries: libraries)
    }

    private func read(_ url: URL, relativePath: String) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ProductionKnowledgeErrorV1.missingResource(relativePath)
        }
    }

    private func resolvedResourceURL(_ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              path.hasSuffix(".json") else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: "manifest.json.resources.path",
                reason: "resource path must be a relative JSON path without traversal"
            )
        }
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = rootURL.appendingPathComponent(path, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: "manifest.json.resources.path",
                reason: "resource resolves outside the knowledge root"
            )
        }
        return candidate
    }

    private func rejectManifestConflicts(
        _ references: [ProductionKnowledgeResourceReferenceV1]
    ) throws {
        let grouped = Dictionary(grouping: references) { "\($0.kind.rawValue):\($0.id)" }
        if let key = grouped.keys.sorted().first(where: {
            grouped[$0, default: []].count > 1
        }), let first = grouped[key]?.first {
            let references = grouped[key, default: []]
            throw ProductionKnowledgeErrorV1.conflictingResource(
                kind: first.kind.rawValue,
                id: first.id,
                versions: references.map { $0.version.rawValue }.sorted()
            )
        }
        let paths = Dictionary(grouping: references, by: \.path)
        if let path = paths.keys.sorted().first(where: {
            paths[$0, default: []].count > 1
        }) {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: "manifest.json.resources.path",
                reason: "duplicate resource path \(path)"
            )
        }
    }

    private func resourceOrder(
        _ lhs: ProductionKnowledgeResourceReferenceV1,
        _ rhs: ProductionKnowledgeResourceReferenceV1
    ) -> Bool {
        (lhs.kind.rawValue, lhs.id, lhs.version.rawValue)
            < (rhs.kind.rawValue, rhs.id, rhs.version.rawValue)
    }
}

final class ProductionKnowledgeCatalogCache: @unchecked Sendable {
    private let lock = NSLock()
    private var catalog: ProductionKnowledgeCatalogV1?

    func load(
        _ loader: () throws -> ProductionKnowledgeCatalogV1
    ) rethrows -> ProductionKnowledgeCatalogV1 {
        lock.lock()
        defer { lock.unlock() }
        if let catalog { return catalog }
        let loaded = try loader()
        catalog = loaded
        return loaded
    }
}

public enum EngineProductionKnowledgeResourcesV1 {
    private static let catalogCache = ProductionKnowledgeCatalogCache()

    public static func rootURL() throws -> URL {
        let fileManager = FileManager.default
        for bundleURL in resourceBundleCandidates() {
            for candidate in roots(inside: bundleURL)
                where isKnowledgeRoot(candidate, fileManager: fileManager) {
                return candidate
            }
        }
        throw ProductionKnowledgeErrorV1.resourceRootMissing
    }

    public static func loadCatalog() throws -> ProductionKnowledgeCatalogV1 {
        try catalogCache.load {
            try ProductionKnowledgeLoaderV1(rootURL: rootURL()).load()
        }
    }

    private static func resourceBundleCandidates() -> [URL] {
        let bundleName = "NexGenEngine_NexGenEngine.bundle"
        var bundles = [Bundle.main]
        if Bundle.main.bundleURL.pathExtension != "app" {
            bundles += Bundle.allFrameworks + Bundle.allBundles
        }
        let startingPoints = bundles.flatMap { bundle in
            [bundle.resourceURL, bundle.bundleURL].compactMap { $0 }
        }
        var candidates: [URL] = []
        for startingPoint in startingPoints {
            var ancestor = startingPoint
            for _ in 0..<6 {
                candidates.append(
                    ancestor.appendingPathComponent(bundleName, isDirectory: true)
                )
                candidates.append(
                    ancestor.appendingPathComponent(
                        "Contents/Resources/\(bundleName)",
                        isDirectory: true
                    )
                )
                let parent = ancestor.deletingLastPathComponent()
                if parent == ancestor { break }
                ancestor = parent
            }
        }
        return candidates
    }

    private static func roots(inside bundleURL: URL) -> [URL] {
        [
            bundleURL.appendingPathComponent("ProductionKnowledge", isDirectory: true),
            bundleURL.appendingPathComponent(
                "Contents/Resources/ProductionKnowledge",
                isDirectory: true
            ),
            bundleURL.appendingPathComponent(
                "Resources/ProductionKnowledge",
                isDirectory: true
            ),
            Bundle(url: bundleURL)?.resourceURL?.appendingPathComponent(
                "ProductionKnowledge",
                isDirectory: true
            ),
        ].compactMap { $0 }
    }

    private static func isKnowledgeRoot(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return fileManager.fileExists(
            atPath: url.appendingPathComponent("manifest.json", isDirectory: false).path
        )
    }
}

private enum ProductionKnowledgeClosedSchemaV1 {
    static func decodeManifest(_ data: Data, path: String) throws -> ProductionKnowledgeManifestV1 {
        let root = try object(data, path: path)
        try exactKeys(root, allowed: ["schemaVersion", "resources"], path: path)
        for (index, item) in try array(root["resources"], path: "\(path).resources").enumerated() {
            try exactKeys(
                try dictionary(item, path: "\(path).resources[\(index)]"),
                allowed: ["kind", "id", "version", "path", "sha256"],
                path: "\(path).resources[\(index)]"
            )
        }
        let manifest: ProductionKnowledgeManifestV1 = try decode(data, path: path)
        guard !manifest.resources.isEmpty else {
            throw invalid("\(path).resources", "must not be empty")
        }
        for (index, resource) in manifest.resources.enumerated() {
            try validID(resource.id, path: "\(path).resources[\(index)].id")
            try validVersion(resource.version, path: "\(path).resources[\(index)].version")
            try validSHA(resource.sha256, path: "\(path).resources[\(index)].sha256")
        }
        return manifest
    }

    static func decodeProfile(_ data: Data, path: String) throws -> ProductionProfileDescriptorV1 {
        let root = try object(data, path: path)
        try ProductionKnowledgeStructuralLintV1.validate(root, path: path)
        try exactKeys(
            root,
            allowed: [
                "schemaVersion", "id", "version", "applicability", "phaseGuidance",
                "machineRules", "provenance", "license",
            ],
            path: path
        )
        try validateApplicability(root["applicability"], path: "\(path).applicability")
        for (index, item) in try array(root["phaseGuidance"], path: "\(path).phaseGuidance").enumerated() {
            try exactKeys(
                try dictionary(item, path: "\(path).phaseGuidance[\(index)]"),
                allowed: ["phase", "instructions"],
                path: "\(path).phaseGuidance[\(index)]"
            )
        }
        for (index, item) in try array(root["machineRules"], path: "\(path).machineRules").enumerated() {
            try exactKeys(
                try dictionary(item, path: "\(path).machineRules[\(index)]"),
                allowed: ["id", "phase", "severity", "predicateID", "message"],
                path: "\(path).machineRules[\(index)]"
            )
        }
        try validateProvenance(root["provenance"], path: "\(path).provenance")
        try validateLicense(root["license"], path: "\(path).license")
        let profile: ProductionProfileDescriptorV1 = try decode(data, path: path)
        guard profile.schemaVersion == "production-profile.v1" else {
            throw invalid("\(path).schemaVersion", "unsupported schema \(profile.schemaVersion)")
        }
        try validID(profile.id.rawValue, path: "\(path).id")
        try validVersion(profile.version, path: "\(path).version")
        try validate(profile.applicability, path: "\(path).applicability")
        guard !profile.phaseGuidance.isEmpty else {
            throw invalid("\(path).phaseGuidance", "must not be empty")
        }
        guard !profile.machineRules.isEmpty else {
            throw invalid("\(path).machineRules", "must not be empty")
        }
        try unique(profile.phaseGuidance.map(\.phase), path: "\(path).phaseGuidance.phase")
        try unique(profile.machineRules.map(\.id), path: "\(path).machineRules.id")
        let applicabilityPhases = Set(profile.applicability.phases)
        guard Set(profile.phaseGuidance.map(\.phase)) == applicabilityPhases else {
            throw invalid(
                "\(path).phaseGuidance.phase",
                "must exactly cover the profile applicability phases"
            )
        }
        guard Set(profile.machineRules.map(\.phase)).isSubset(of: applicabilityPhases) else {
            throw invalid(
                "\(path).machineRules.phase",
                "must be contained in the profile applicability phases"
            )
        }
        for (index, guidance) in profile.phaseGuidance.enumerated() {
            try validID(guidance.phase, path: "\(path).phaseGuidance[\(index)].phase")
            try nonempty(guidance.instructions, path: "\(path).phaseGuidance[\(index)].instructions")
        }
        for (index, rule) in profile.machineRules.enumerated() {
            try validID(rule.id, path: "\(path).machineRules[\(index)].id")
            try validID(rule.phase, path: "\(path).machineRules[\(index)].phase")
            try validID(rule.predicateID, path: "\(path).machineRules[\(index)].predicateID")
            try nonempty(rule.message, path: "\(path).machineRules[\(index)].message")
        }
        try validate(profile.provenance, path: "\(path).provenance")
        try validate(profile.license, path: "\(path).license")
        return profile
    }

    static func decodeLibrary(_ data: Data, path: String) throws -> CreativeKnowledgeLibraryV1 {
        let root = try object(data, path: path)
        try ProductionKnowledgeStructuralLintV1.validate(root, path: path)
        try exactKeys(
            root,
            allowed: [
                "schemaVersion", "id", "version", "applicability", "entries",
                "provenance", "license",
            ],
            path: path
        )
        try validateApplicability(root["applicability"], path: "\(path).applicability")
        for (index, item) in try array(root["entries"], path: "\(path).entries").enumerated() {
            let entryPath = "\(path).entries[\(index)]"
            let entry = try dictionary(item, path: entryPath)
            try exactKeys(
                entry,
                allowed: [
                    "id", "title", "applicability", "inputs", "outputIntent", "guidance",
                    "verifyCriteria", "incompatibilities",
                ],
                path: entryPath
            )
            try validateApplicability(entry["applicability"], path: "\(entryPath).applicability")
            for (inputIndex, input) in try array(entry["inputs"], path: "\(entryPath).inputs").enumerated() {
                try exactKeys(
                    try dictionary(input, path: "\(entryPath).inputs[\(inputIndex)]"),
                    allowed: ["role", "purpose", "required"],
                    path: "\(entryPath).inputs[\(inputIndex)]"
                )
            }
        }
        try validateProvenance(root["provenance"], path: "\(path).provenance")
        try validateLicense(root["license"], path: "\(path).license")
        let library: CreativeKnowledgeLibraryV1 = try decode(data, path: path)
        guard library.schemaVersion == "creative-library.v1" else {
            throw invalid("\(path).schemaVersion", "unsupported schema \(library.schemaVersion)")
        }
        try validID(library.id.rawValue, path: "\(path).id")
        try validVersion(library.version, path: "\(path).version")
        try validate(library.applicability, path: "\(path).applicability")
        guard !library.entries.isEmpty else {
            throw invalid("\(path).entries", "must not be empty")
        }
        try unique(library.entries.map { $0.id.rawValue }, path: "\(path).entries.id")
        for (index, entry) in library.entries.enumerated() {
            let entryPath = "\(path).entries[\(index)]"
            try validID(entry.id.rawValue, path: "\(entryPath).id")
            try nonempty(entry.title, path: "\(entryPath).title")
            try validate(entry.applicability, path: "\(entryPath).applicability")
            guard Set(entry.applicability.phases).isSubset(
                of: Set(library.applicability.phases)
            ) else {
                throw invalid(
                    "\(entryPath).applicability.phases",
                    "must be contained in the library applicability phases"
                )
            }
            try nonempty(entry.outputIntent, path: "\(entryPath).outputIntent")
            try nonempty(entry.guidance, path: "\(entryPath).guidance")
            try nonempty(entry.verifyCriteria, path: "\(entryPath).verifyCriteria")
            for (inputIndex, input) in entry.inputs.enumerated() {
                try validID(input.role, path: "\(entryPath).inputs[\(inputIndex)].role")
                try ProductionKnowledgeStructuralLintV1.validateInputRole(
                    input.role,
                    path: "\(entryPath).inputs[\(inputIndex)].role"
                )
                try nonempty(input.purpose, path: "\(entryPath).inputs[\(inputIndex)].purpose")
            }
        }
        try validate(library.provenance, path: "\(path).provenance")
        try validate(library.license, path: "\(path).license")
        return library
    }

    private static func object(_ data: Data, path: String) throws -> [String: Any] {
        do {
            return try dictionary(
                JSONSerialization.jsonObject(with: data, options: []),
                path: path
            )
        } catch let error as ProductionKnowledgeErrorV1 {
            throw error
        } catch {
            throw ProductionKnowledgeErrorV1.invalidJSON(path: path, reason: error.localizedDescription)
        }
    }

    private static func decode<T: Decodable>(_ data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProductionKnowledgeErrorV1.invalidJSON(path: path, reason: error.localizedDescription)
        }
    }

    private static func dictionary(_ value: Any?, path: String) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw ProductionKnowledgeErrorV1.invalidJSON(path: path, reason: "expected object")
        }
        return dictionary
    }

    private static func array(_ value: Any?, path: String) throws -> [Any] {
        guard let array = value as? [Any] else {
            throw ProductionKnowledgeErrorV1.invalidJSON(path: path, reason: "expected array")
        }
        return array
    }

    private static func exactKeys(_ object: [String: Any], allowed: Set<String>, path: String) throws {
        let actual = Set(object.keys)
        guard actual == allowed else {
            let unknown = actual.subtracting(allowed).sorted()
            let missing = allowed.subtracting(actual).sorted()
            var reasons: [String] = []
            if !unknown.isEmpty { reasons.append("unknown keys: \(unknown.joined(separator: ", "))") }
            if !missing.isEmpty { reasons.append("missing keys: \(missing.joined(separator: ", "))") }
            throw ProductionKnowledgeErrorV1.invalidJSON(path: path, reason: reasons.joined(separator: "; "))
        }
    }

    private static func validateApplicability(_ value: Any?, path: String) throws {
        try exactKeys(
            try dictionary(value, path: path),
            allowed: ["packIDs", "phases", "intentTags", "activeProfileIDs"],
            path: path
        )
    }

    private static func validateProvenance(_ value: Any?, path: String) throws {
        try exactKeys(
            try dictionary(value, path: path),
            allowed: ["sourceURL", "sourceCommit", "sourceSections", "adaptation"],
            path: path
        )
    }

    private static func validateLicense(_ value: Any?, path: String) throws {
        try exactKeys(
            try dictionary(value, path: path),
            allowed: ["spdxIdentifier", "copyrightNotice", "sourceURL"],
            path: path
        )
    }

    private static func validate(_ applicability: ProductionKnowledgeApplicabilityV1, path: String) throws {
        try unique(applicability.packIDs, path: "\(path).packIDs")
        try unique(applicability.phases, path: "\(path).phases")
        try unique(applicability.intentTags, path: "\(path).intentTags")
        try unique(applicability.activeProfileIDs.map(\.rawValue), path: "\(path).activeProfileIDs")
        try nonempty(applicability.packIDs, path: "\(path).packIDs", allowEmptyArray: true)
        try nonempty(applicability.phases, path: "\(path).phases")
        try nonempty(applicability.intentTags, path: "\(path).intentTags")
        for (index, id) in applicability.packIDs.enumerated() {
            try validID(id, path: "\(path).packIDs[\(index)]")
        }
        for (index, id) in applicability.phases.enumerated() {
            try validID(id, path: "\(path).phases[\(index)]")
        }
        for (index, id) in applicability.intentTags.enumerated() {
            try validID(id, path: "\(path).intentTags[\(index)]")
        }
        for (index, id) in applicability.activeProfileIDs.enumerated() {
            try validID(id.rawValue, path: "\(path).activeProfileIDs[\(index)]")
        }
    }

    private static func validate(_ provenance: ProductionKnowledgeProvenanceV1, path: String) throws {
        guard let url = URL(string: provenance.sourceURL), url.scheme == "https" else {
            throw invalid("\(path).sourceURL", "must be an https URL")
        }
        try validHex(provenance.sourceCommit, length: 40, path: "\(path).sourceCommit")
        try nonempty(provenance.sourceSections, path: "\(path).sourceSections")
        try nonempty(provenance.adaptation, path: "\(path).adaptation")
    }

    private static func validate(_ license: ProductionKnowledgeLicenseV1, path: String) throws {
        try nonempty(license.spdxIdentifier, path: "\(path).spdxIdentifier")
        try nonempty(license.copyrightNotice, path: "\(path).copyrightNotice")
        guard let url = URL(string: license.sourceURL), url.scheme == "https" else {
            throw invalid("\(path).sourceURL", "must be an https URL")
        }
    }

    private static func validID(_ value: String, path: String) throws {
        let scalars = value.unicodeScalars
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard let first = scalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first),
              scalars.allSatisfy(allowed.contains) else {
            throw invalid(path, "must be a lower-case stable identifier")
        }
    }

    private static func validVersion(_ value: ProductionKnowledgeVersionV1, path: String) throws {
        let components = value.rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
              }) else {
            throw invalid(path, "must be MAJOR.MINOR.PATCH with ASCII digits")
        }
    }

    private static func validSHA(_ value: String, path: String) throws {
        try validHex(value, length: 64, path: path)
    }

    private static func validHex(_ value: String, length: Int, path: String) throws {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.unicodeScalars.count == length,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw invalid(path, "must be \(length) lower-case hexadecimal characters")
        }
    }

    private static func unique(_ values: [String], path: String) throws {
        guard Set(values).count == values.count else {
            throw invalid(path, "contains duplicate values")
        }
    }

    private static func nonempty(_ value: String, path: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid(path, "must not be empty")
        }
    }

    private static func nonempty(
        _ values: [String],
        path: String,
        allowEmptyArray: Bool = false
    ) throws {
        if !allowEmptyArray && values.isEmpty {
            throw invalid(path, "must not be empty")
        }
        for (index, value) in values.enumerated() {
            try nonempty(value, path: "\(path)[\(index)]")
        }
    }

    private static func invalid(_ path: String, _ reason: String) -> ProductionKnowledgeErrorV1 {
        .invalidValue(path: path, reason: reason)
    }
}
private enum ProductionKnowledgeStructuralLintV1 {
    private static let forbiddenObjectKeys: Set<String> = [
        "providerid", "providerids", "modelid", "modelids",
        "capability", "capabilities", "capabilityfield", "capabilityfields",
        "capabilitylimit", "capabilitylimits", "characterlimit", "durationlimit",
        "referencelimit", "referencecountlimit", "requestparameter", "requestparameters",
        "requestsyntax", "providersyntax", "modelsyntax", "endpointparameter",
        "endpointparameters", "executableparameter", "executableparameters",
        "projectid", "projectids", "projectassetid", "projectassetids",
        "projectcanon", "canonartifactid", "canonassetid", "assetpath", "assetpaths",
    ]

    private static let forbiddenTypedRoles: Set<String> = [
        "provider", "providerid", "providerids", "model", "modelid", "modelids",
        "capability", "capabilityfield", "capabilitylimit", "requestparameter",
        "requestsyntax", "endpointparameter", "projectid", "projectassetid",
        "canonartifactid", "canonassetid", "assetpath",
    ]

    static func validate(_ value: Any, path: String) throws {
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                let normalized = normalize(key)
                guard !forbiddenObjectKeys.contains(normalized) else {
                    throw ProductionKnowledgeErrorV1.invalidValue(
                        path: "\(path).\(key)",
                        reason: "forbidden structural production-knowledge field \(key)"
                    )
                }
                if let nested = object[key] {
                    try validate(nested, path: "\(path).\(key)")
                }
            }
        } else if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                try validate(nested, path: "\(path)[\(index)]")
            }
        }
    }

    static func validateInputRole(_ role: String, path: String) throws {
        let normalized = normalize(role)
        let tokens = Set(
            role.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let typedIdentity = !tokens.isDisjoint(with: ["provider", "model", "capability"])
        let typedRequest = tokens.contains("request")
            && !tokens.isDisjoint(with: ["field", "parameter", "syntax"])
        let typedLimit = tokens.contains("limit")
            && !tokens.isDisjoint(with: ["capability", "character", "duration", "reference"])
        let typedCapabilityField =
            (!tokens.isDisjoint(with: ["capacity", "count", "maximum", "minimum", "total"])
                && !tokens.isDisjoint(with: ["character", "characters", "duration", "reference", "references"]))
            || (tokens.contains("visible") && tokens.contains("characters"))
        let projectAsset = tokens.contains("project")
            && !tokens.isDisjoint(with: ["asset", "canon"])
        let canonAsset = tokens.contains("canon")
            && !tokens.isDisjoint(with: ["artifact", "asset", "id"])
        let assetPath = tokens == Set(["asset", "path"])
        guard !forbiddenTypedRoles.contains(normalized),
              !typedIdentity,
              !typedRequest,
              !typedLimit,
              !typedCapabilityField,
              !projectAsset,
              !canonAsset,
              !assetPath else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: path,
                reason: "provider, model, capability, request, and project-asset identifiers are not creative-knowledge inputs"
            )
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map { String($0) }
            .joined()
    }
}
