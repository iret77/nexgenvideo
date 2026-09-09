import Foundation

public struct BibleIdentityVariantV1: Codable, Sendable, Equatable {
    public let baseEntityID: String
    public let variantEntityID: String
    public let changedAttributes: [String: String]
    public let inheritedIdentityPaths: [String]

    private enum CodingKeys: String, CodingKey {
        case baseEntityID = "base_entity_id"
        case variantEntityID = "variant_entity_id"
        case changedAttributes = "changed_attributes"
        case inheritedIdentityPaths = "inherited_identity_paths"
    }

    public init(
        baseEntityID: String,
        variantEntityID: String,
        changedAttributes: [String: String],
        inheritedIdentityPaths: [String]
    ) {
        self.baseEntityID = baseEntityID
        self.variantEntityID = variantEntityID
        self.changedAttributes = changedAttributes
        self.inheritedIdentityPaths = inheritedIdentityPaths
    }
}

public struct BibleIdentityVariantsV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "bible-identity-variants/v1"

    public let schema: String
    public let project: String
    public let revision: Int
    public let variants: [BibleIdentityVariantV1]

    public init(
        schema: String = schemaVersion,
        project: String,
        revision: Int,
        variants: [BibleIdentityVariantV1]
    ) {
        self.schema = schema
        self.project = project
        self.revision = revision
        self.variants = variants
    }
}

public enum BibleIdentityVariantValidationErrorV1: Error, Sendable,
    Equatable {
    case invalidIdentity
    case unknownEntity(String)
    case kindMismatch(String)
    case invalidAttributes(String)
    case invalidAnchor(String)
    case cyclicInheritance(String)
}

public enum BibleIdentityVariantStoreV1 {
    private struct Entity {
        let kind: String
        let attributes: [String: String]
        let anchors: Set<String>
        let sheets: Set<String>
    }

    public static func loadIfPresent(dataRoot: URL) throws
        -> BibleIdentityVariantsV1? {
        let url = PipelineLayout.url(
            PipelineLayout.bibleIdentityVariantsFile,
            in: dataRoot
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try JSONArtifactStore(dataRoot: dataRoot).load(
            BibleIdentityVariantsV1.self,
            at: PipelineLayout.bibleIdentityVariantsFile
        )
    }

    public static func save(
        _ artifact: BibleIdentityVariantsV1,
        bible: Bible,
        dataRoot: URL
    ) throws {
        try validate(artifact, bible: bible, dataRoot: dataRoot)
        try JSONArtifactStore(dataRoot: dataRoot).save(
            artifact,
            to: PipelineLayout.bibleIdentityVariantsFile
        )
    }

    public static func validate(
        _ artifact: BibleIdentityVariantsV1,
        bible: Bible,
        dataRoot: URL
    ) throws {
        guard artifact.schema == BibleIdentityVariantsV1.schemaVersion,
              artifact.project == bible.project,
              artifact.revision > 0,
              Set(artifact.variants.map(\.variantEntityID)).count
                == artifact.variants.count else {
            throw BibleIdentityVariantValidationErrorV1.invalidIdentity
        }
        let entities = entityMap(bible)
        let variantsByID = Dictionary(uniqueKeysWithValues:
            artifact.variants.map { ($0.variantEntityID, $0) }
        )
        for variant in artifact.variants {
            guard variant.baseEntityID != variant.variantEntityID,
                  let base = entities[variant.baseEntityID],
                  let derived = entities[variant.variantEntityID] else {
                throw BibleIdentityVariantValidationErrorV1.unknownEntity(
                    variant.variantEntityID
                )
            }
            guard base.kind == derived.kind else {
                throw BibleIdentityVariantValidationErrorV1.kindMismatch(
                    variant.variantEntityID
                )
            }
            let changed = variant.changedAttributes
            guard !changed.isEmpty,
                  changed.allSatisfy({ key, value in
                    !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && derived.attributes[key] == value
                        && base.attributes[key] != value
                  }),
                  derived.attributes.allSatisfy({ key, value in
                    changed[key] == value || base.attributes[key] == value
                  }),
                  base.attributes.allSatisfy({ key, value in
                    changed[key] != nil || derived.attributes[key] == value
                  }) else {
                throw BibleIdentityVariantValidationErrorV1.invalidAttributes(
                    variant.variantEntityID
                )
            }
            let inherited = Set(variant.inheritedIdentityPaths)
            guard !inherited.isEmpty,
                  inherited.count == variant.inheritedIdentityPaths.count,
                  inherited.isSubset(of: base.anchors),
                  !derived.sheets.isEmpty,
                  base.anchors.isDisjoint(with: derived.sheets) else {
                throw BibleIdentityVariantValidationErrorV1.invalidAnchor(
                    variant.variantEntityID
                )
            }
            for path in inherited.union(derived.sheets) {
                do {
                    let url = try ProjectLocalFile.resolve(
                        path,
                        dataRoot: dataRoot
                    )
                    let values = try url.resourceValues(
                        forKeys: [.isRegularFileKey]
                    )
                    guard values.isRegularFile == true,
                          ProjectMediaExtensions.images.contains(
                            url.pathExtension.lowercased()
                          ) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                } catch {
                    throw BibleIdentityVariantValidationErrorV1.invalidAnchor(
                        variant.variantEntityID
                    )
                }
            }
            var seen = Set<String>()
            var current = variant.variantEntityID
            while let parent = variantsByID[current]?.baseEntityID,
                  variantsByID[parent] != nil {
                guard seen.insert(current).inserted else {
                    throw BibleIdentityVariantValidationErrorV1
                        .cyclicInheritance(variant.variantEntityID)
                }
                current = parent
            }
        }
    }

    private static func entityMap(_ bible: Bible) -> [String: Entity] {
        var result: [String: Entity] = [:]
        for item in bible.characters {
            result[item.id] = Entity(
                kind: "character",
                attributes: item.attributes,
                anchors: Set(item.referenceImages + Array(item.sheets.values)),
                sheets: Set(Array(item.sheets.values))
            )
        }
        for item in bible.ensembles {
            result[item.id] = Entity(
                kind: "ensemble",
                attributes: item.attributes,
                anchors: Set(item.referenceImages + Array(item.sheets.values)),
                sheets: Set(Array(item.sheets.values))
            )
        }
        for item in bible.props {
            result[item.id] = Entity(
                kind: "prop",
                attributes: item.attributes,
                anchors: Set(item.referenceImages + Array(item.sheets.values)),
                sheets: Set(Array(item.sheets.values))
            )
        }
        for item in bible.locations {
            result[item.id] = Entity(
                kind: "location",
                attributes: item.attributes,
                anchors: Set(item.referenceImages + Array(item.sheets.values)),
                sheets: Set(Array(item.sheets.values))
            )
        }
        return result
    }
}
