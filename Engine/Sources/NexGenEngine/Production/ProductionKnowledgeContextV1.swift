import Foundation

public struct ProductionKnowledgeBudgetV1: Sendable, Equatable {
    public let maximumUTF8Bytes: Int
    public let maximumEstimatedTokens: Int

    public init(maximumUTF8Bytes: Int, maximumEstimatedTokens: Int) {
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.maximumEstimatedTokens = maximumEstimatedTokens
    }
}

public struct ProductionKnowledgeActivationMetadataV1: Sendable, Equatable {
    public let values: [String: String]
    public let intentTags: Set<String>
    public let activeLibraryIDs: Set<CreativeKnowledgeLibraryIDV1>?

    public init(
        values: [String: String] = [:],
        intentTags: Set<String> = [],
        activeLibraryIDs: Set<CreativeKnowledgeLibraryIDV1>? = nil
    ) {
        self.values = values
        self.intentTags = intentTags
        self.activeLibraryIDs = activeLibraryIDs
    }
}

public struct ProductionKnowledgePhaseSelectionV1: Sendable, Equatable {
    public let phase: String
    public let knowledgePhase: String
    public let libraryIDs: [CreativeKnowledgeLibraryIDV1]
    public let intentTags: Set<String>

    public init(
        phase: String,
        knowledgePhase: String? = nil,
        libraryIDs: [CreativeKnowledgeLibraryIDV1],
        intentTags: Set<String>
    ) {
        self.phase = phase
        self.knowledgePhase = knowledgePhase ?? phase
        self.libraryIDs = libraryIDs
        self.intentTags = intentTags
    }
}

public struct ProductionKnowledgeConsumerDescriptorV1: Sendable, Equatable {
    public let id: String
    public let version: ProductionKnowledgeVersionV1
    public let packID: String
    public let profileResourceIDs: Set<ProductionProfileDescriptorIDV1>
    public let phaseSelections: [ProductionKnowledgePhaseSelectionV1]
    public let budget: ProductionKnowledgeBudgetV1

    public init(
        id: String,
        version: ProductionKnowledgeVersionV1,
        packID: String,
        profileResourceIDs: Set<ProductionProfileDescriptorIDV1>,
        phaseSelections: [ProductionKnowledgePhaseSelectionV1],
        budget: ProductionKnowledgeBudgetV1
    ) {
        self.id = id
        self.version = version
        self.packID = packID
        self.profileResourceIDs = profileResourceIDs
        self.phaseSelections = phaseSelections
        self.budget = budget
    }

    public func selection(for phase: String) -> ProductionKnowledgePhaseSelectionV1? {
        phaseSelections.first { $0.phase == phase }
    }
}

public typealias ProductionKnowledgeActivationMetadataProviderV1 =
    @Sendable (URL, String) throws -> ProductionKnowledgeActivationMetadataV1

public struct ProductionKnowledgeConsumerRegistrationV1: Sendable {
    public let descriptor: ProductionKnowledgeConsumerDescriptorV1
    public let metadataProvider: ProductionKnowledgeActivationMetadataProviderV1

    public init(
        descriptor: ProductionKnowledgeConsumerDescriptorV1,
        metadataProvider: @escaping ProductionKnowledgeActivationMetadataProviderV1
    ) {
        self.descriptor = descriptor
        self.metadataProvider = metadataProvider
    }
}

public struct ProductionKnowledgeConsumerRegistryV1: Sendable {
    private let byPackID: [String: ProductionKnowledgeConsumerRegistrationV1]

    public init(registrations: [ProductionKnowledgeConsumerRegistrationV1]) throws {
        let grouped = Dictionary(grouping: registrations, by: {
            $0.descriptor.packID
        })
        if let packID = grouped.keys.sorted().first(where: {
            grouped[$0, default: []].count > 1
        }) {
            let matches = grouped[packID, default: []]
            throw ProductionKnowledgeErrorV1.conflictingResource(
                kind: "consumer",
                id: packID,
                versions: matches.map { $0.descriptor.version.rawValue }.sorted()
            )
        }
        for registration in registrations {
            try Self.validate(registration.descriptor)
        }
        byPackID = Dictionary(
            uniqueKeysWithValues: registrations.map { ($0.descriptor.packID, $0) }
        )
    }

    public func registration(
        for packID: String
    ) -> ProductionKnowledgeConsumerRegistrationV1? {
        byPackID[packID]
    }

    public func validateResources(in catalog: ProductionKnowledgeCatalogV1) throws {
        for registration in byPackID.values.sorted(by: {
            $0.descriptor.packID < $1.descriptor.packID
        }) {
            let descriptor = registration.descriptor
            for profileID in descriptor.profileResourceIDs.sorted(by: {
                $0.rawValue < $1.rawValue
            }) where catalog.profile(id: profileID) == nil {
                throw ProductionKnowledgeErrorV1.missingResource(
                    "consumer:\(descriptor.id):profile:\(profileID.rawValue)"
                )
            }
            for selection in descriptor.phaseSelections.sorted(by: {
                $0.phase < $1.phase
            }) {
                for libraryID in selection.libraryIDs.sorted(by: {
                    $0.rawValue < $1.rawValue
                }) {
                    guard let library = catalog.library(id: libraryID) else {
                        throw ProductionKnowledgeErrorV1.missingResource(
                            "consumer:\(descriptor.id):library:\(libraryID.rawValue)"
                        )
                    }
                    guard library.applicability.phases.contains(
                        selection.knowledgePhase
                    ) else {
                        throw ProductionKnowledgeErrorV1.invalidValue(
                            path: "consumer.phaseSelections.libraryIDs",
                            reason: "library \(libraryID.rawValue) does not apply to knowledge phase \(selection.knowledgePhase)"
                        )
                    }
                }
            }
        }
    }

    private static func validate(_ descriptor: ProductionKnowledgeConsumerDescriptorV1) throws {
        try requireIdentifier(descriptor.id, path: "consumer.id")
        try requireIdentifier(descriptor.packID, path: "consumer.packID")
        try requireVersion(descriptor.version, path: "consumer.version")
        for profileID in descriptor.profileResourceIDs {
            try requireIdentifier(
                profileID.rawValue,
                path: "consumer.profileResourceIDs"
            )
        }
        guard descriptor.budget.maximumUTF8Bytes > 0,
              descriptor.budget.maximumEstimatedTokens > 0 else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: "consumer.budget",
                reason: "byte and token budgets must be positive"
            )
        }
        let phases = descriptor.phaseSelections.map(\.phase)
        guard Set(phases).count == phases.count else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: "consumer.phaseSelections.phase",
                reason: "contains duplicate phase identifiers"
            )
        }
        for selection in descriptor.phaseSelections {
            try requireIdentifier(selection.phase, path: "consumer.phaseSelections.phase")
            try requireIdentifier(
                selection.knowledgePhase,
                path: "consumer.phaseSelections.knowledgePhase"
            )
            let libraryIDs = selection.libraryIDs.map(\.rawValue)
            guard Set(libraryIDs).count == libraryIDs.count else {
                throw ProductionKnowledgeErrorV1.invalidValue(
                    path: "consumer.phaseSelections.libraryIDs",
                    reason: "contains duplicate library identifiers"
                )
            }
            for libraryID in libraryIDs {
                try requireIdentifier(
                    libraryID,
                    path: "consumer.phaseSelections.libraryIDs"
                )
            }
            for intentTag in selection.intentTags {
                try requireIdentifier(
                    intentTag,
                    path: "consumer.phaseSelections.intentTags"
                )
            }
        }
    }

    private static func requireIdentifier(_ value: String, path: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard let first = value.unicodeScalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first),
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: path,
                reason: "must be a lower-case stable identifier"
            )
        }
    }

    private static func requireVersion(
        _ version: ProductionKnowledgeVersionV1,
        path: String
    ) throws {
        let components = version.rawValue.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              components.allSatisfy({ component in
                  !component.isEmpty && component.unicodeScalars.allSatisfy {
                      (48...57).contains($0.value)
                  }
              }) else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: path,
                reason: "must be MAJOR.MINOR.PATCH with ASCII digits"
            )
        }
    }
}

public enum ProductionMachinePredicateEnforcementV1: String, Sendable, Equatable {
    case executionPlanValidator = "execution-plan-validator.v1"
    case coreSanityAudit = "core-sanity-audit.v1"
}

public struct ProductionMachinePredicateBindingV1: Sendable, Equatable {
    public let predicateID: String
    public let phases: Set<String>
    public let enforcement: ProductionMachinePredicateEnforcementV1

    public init(
        predicateID: String,
        phases: Set<String>,
        enforcement: ProductionMachinePredicateEnforcementV1
    ) {
        self.predicateID = predicateID
        self.phases = phases
        self.enforcement = enforcement
    }
}

public struct ProductionMachinePredicateRegistryV1: Sendable {
    private let bindings: [String: ProductionMachinePredicateBindingV1]

    public init(bindings: [ProductionMachinePredicateBindingV1]) throws {
        let grouped = Dictionary(grouping: bindings, by: \.predicateID)
        if let predicateID = grouped.keys.sorted().first(where: {
            grouped[$0, default: []].count > 1
        }) {
            let duplicates = grouped[predicateID, default: []]
            throw ProductionKnowledgeErrorV1.conflictingResource(
                kind: "machine-predicate",
                id: predicateID,
                versions: duplicates.map { $0.enforcement.rawValue }.sorted()
            )
        }
        self.bindings = Dictionary(uniqueKeysWithValues: bindings.map { ($0.predicateID, $0) })
    }

    public func binding(
        for predicateID: String,
        phase: String
    ) throws -> ProductionMachinePredicateBindingV1 {
        guard let binding = bindings[predicateID], binding.phases.contains(phase) else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: "machineRules.predicateID",
                reason: "unbound machine predicate \(predicateID) for phase \(phase)"
            )
        }
        return binding
    }

    public static func standard() throws -> Self {
        try Self(bindings: [
            ProductionMachinePredicateBindingV1(
                predicateID: "execution_plan.has_start_end_states",
                phases: ["shotlist"],
                enforcement: .executionPlanValidator
            ),
            ProductionMachinePredicateBindingV1(
                predicateID: "execution_plan.has_single_primary_action",
                phases: ["shotlist"],
                enforcement: .executionPlanValidator
            ),
            ProductionMachinePredicateBindingV1(
                predicateID: "execution_plan.camera_plan_is_coherent",
                phases: ["shotlist"],
                enforcement: .executionPlanValidator
            ),
            ProductionMachinePredicateBindingV1(
                predicateID: "execution_plan.blocking_and_physics_are_declared",
                phases: ["shotlist"],
                enforcement: .executionPlanValidator
            ),
            ProductionMachinePredicateBindingV1(
                predicateID: "execution_plan.material_risks_have_rescues",
                phases: ["shotlist"],
                enforcement: .executionPlanValidator
            ),
            ProductionMachinePredicateBindingV1(
                predicateID: "execution_plan.narrative_beat_is_declared",
                phases: ["shotlist"],
                enforcement: .coreSanityAudit
            ),
            ProductionMachinePredicateBindingV1(
                predicateID: "sequence.context_action_consequence_are_visible",
                phases: ["review"],
                enforcement: .coreSanityAudit
            ),
        ])
    }
}

public struct ResolvedProductionMachineRuleV1: Sendable, Equatable {
    public let rule: ProductionMachineRuleV1
    public let binding: ProductionMachinePredicateBindingV1

    public init(
        rule: ProductionMachineRuleV1,
        binding: ProductionMachinePredicateBindingV1
    ) {
        self.rule = rule
        self.binding = binding
    }
}

public struct ProductionKnowledgeAssemblyQueryV1: Sendable, Equatable {
    public let packID: String
    public let phase: String
    public let intentTags: Set<String>
    public let activeProfileIDs: Set<ProductionProfileDescriptorIDV1>
    public let activeLibraryIDs: Set<CreativeKnowledgeLibraryIDV1>
    public let budget: ProductionKnowledgeBudgetV1

    public init(
        packID: String,
        phase: String,
        intentTags: Set<String>,
        activeProfileIDs: Set<ProductionProfileDescriptorIDV1>,
        activeLibraryIDs: Set<CreativeKnowledgeLibraryIDV1>,
        budget: ProductionKnowledgeBudgetV1
    ) {
        self.packID = packID
        self.phase = phase
        self.intentTags = intentTags
        self.activeProfileIDs = activeProfileIDs
        self.activeLibraryIDs = activeLibraryIDs
        self.budget = budget
    }
}

public struct ProductionKnowledgeAssemblyV1: Sendable, Equatable {
    public let prompt: String
    public let profileIDs: [ProductionProfileDescriptorIDV1]
    public let libraryEntryIDs: [String]
    public let omittedLibraryEntryIDs: [String]
    public let machineRules: [ResolvedProductionMachineRuleV1]
    public let utf8Bytes: Int
    public let estimatedTokens: Int

    public init(
        prompt: String,
        profileIDs: [ProductionProfileDescriptorIDV1],
        libraryEntryIDs: [String],
        omittedLibraryEntryIDs: [String],
        machineRules: [ResolvedProductionMachineRuleV1],
        utf8Bytes: Int,
        estimatedTokens: Int
    ) {
        self.prompt = prompt
        self.profileIDs = profileIDs
        self.libraryEntryIDs = libraryEntryIDs
        self.omittedLibraryEntryIDs = omittedLibraryEntryIDs
        self.machineRules = machineRules
        self.utf8Bytes = utf8Bytes
        self.estimatedTokens = estimatedTokens
    }
}

public struct ProductionKnowledgeContextAssemblerV1: Sendable {
    public let catalog: ProductionKnowledgeCatalogV1
    public let predicates: ProductionMachinePredicateRegistryV1

    public init(
        catalog: ProductionKnowledgeCatalogV1,
        predicates: ProductionMachinePredicateRegistryV1
    ) {
        self.catalog = catalog
        self.predicates = predicates
    }

    public func assemble(
        _ query: ProductionKnowledgeAssemblyQueryV1
    ) throws -> ProductionKnowledgeAssemblyV1 {
        guard query.budget.maximumUTF8Bytes > 0,
              query.budget.maximumEstimatedTokens > 0 else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: "assembly.budget",
                reason: "byte and token budgets must be positive"
            )
        }
        let profiles = try query.activeProfileIDs.map { id in
            guard let profile = catalog.profile(id: id) else {
                throw ProductionKnowledgeErrorV1.missingResource("profile:\(id.rawValue)")
            }
            return profile
        }
        let applicableProfiles = profiles.filter {
            applies(
                $0.applicability,
                packID: query.packID,
                phase: query.phase,
                intents: query.intentTags,
                profiles: query.activeProfileIDs,
                requiresIntentMatch: false
            )
        }
        let effectiveProfile = try EffectiveProductionProfileV1(
            descriptors: applicableProfiles
        )
        let resolvedRules = try effectiveProfile.machineRules
            .filter { $0.phase == query.phase }
            .sorted { $0.id < $1.id }
            .map { rule in
                ResolvedProductionMachineRuleV1(
                    rule: rule,
                    binding: try predicates.binding(
                        for: rule.predicateID,
                        phase: rule.phase
                    )
                )
            }

        let libraries = try query.activeLibraryIDs.map { id in
            guard let library = catalog.library(id: id) else {
                throw ProductionKnowledgeErrorV1.missingResource("library:\(id.rawValue)")
            }
            return library
        }
        let effectiveLibraries = try EffectiveCreativeKnowledgeLibrariesV1(libraries: libraries)

        var requiredChunks: [(id: String, text: String)] = []
        for descriptor in effectiveProfile.descriptors {
            guard let guidance = descriptor.phaseGuidance.first(where: {
                $0.phase == query.phase
            }) else { continue }
            requiredChunks.append((
                id: "profile:\(descriptor.id.rawValue)",
                text: renderProfile(descriptor, guidance: guidance)
            ))
        }

        var optionalChunks: [(id: String, text: String)] = []
        for library in effectiveLibraries.libraries {
            guard applies(
                library.applicability,
                packID: query.packID,
                phase: query.phase,
                intents: query.intentTags,
                profiles: query.activeProfileIDs,
                requiresIntentMatch: true
            ) else { continue }
            for entry in library.entries where applies(
                entry.applicability,
                packID: query.packID,
                phase: query.phase,
                intents: query.intentTags,
                profiles: query.activeProfileIDs,
                requiresIntentMatch: true
            ) {
                let id = "\(library.id.rawValue)/\(entry.id.rawValue)"
                optionalChunks.append((id: id, text: renderEntry(library, entry: entry)))
            }
        }
        optionalChunks.sort { $0.id < $1.id }

        let totalEntryCount = catalog.libraries.reduce(0) { $0 + $1.entries.count }
        if totalEntryCount > 0, optionalChunks.count == totalEntryCount {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: "assembly.selection",
                reason: "whole-corpus prompt assembly is forbidden"
            )
        }

        var chunks: [String] = []
        var includedEntryIDs: [String] = []
        var omittedEntryIDs: [String] = []
        for chunk in requiredChunks.sorted(by: { $0.id < $1.id }) {
            guard fits(chunks + [chunk.text], budget: query.budget) else {
                throw ProductionKnowledgeErrorV1.invalidValue(
                    path: "assembly.budget",
                    reason: "required profile guidance \(chunk.id) exceeds the configured budget"
                )
            }
            chunks.append(chunk.text)
        }
        for chunk in optionalChunks {
            if fits(chunks + [chunk.text], budget: query.budget) {
                chunks.append(chunk.text)
                includedEntryIDs.append(chunk.id)
            } else {
                omittedEntryIDs.append(chunk.id)
            }
        }
        let prompt = chunks.joined(separator: "\n\n")
        return ProductionKnowledgeAssemblyV1(
            prompt: prompt,
            profileIDs: effectiveProfile.descriptors.map(\.id),
            libraryEntryIDs: includedEntryIDs,
            omittedLibraryEntryIDs: omittedEntryIDs,
            machineRules: resolvedRules,
            utf8Bytes: prompt.utf8.count,
            estimatedTokens: Self.estimatedTokens(prompt)
        )
    }

    private func applies(
        _ applicability: ProductionKnowledgeApplicabilityV1,
        packID: String,
        phase: String,
        intents: Set<String>,
        profiles: Set<ProductionProfileDescriptorIDV1>,
        requiresIntentMatch: Bool
    ) -> Bool {
        let packMatches = applicability.packIDs.isEmpty
            || applicability.packIDs.contains(packID)
        let phaseMatches = applicability.phases.contains(phase)
        let intentMatches = !requiresIntentMatch
            || !Set(applicability.intentTags).isDisjoint(with: intents)
        let profileMatches = Set(applicability.activeProfileIDs).isSubset(of: profiles)
        return packMatches && phaseMatches && intentMatches && profileMatches
    }

    private func renderProfile(
        _ descriptor: ProductionProfileDescriptorV1,
        guidance: ProductionPhaseGuidanceV1
    ) -> String {
        let instructions = guidance.instructions.map { "- \($0)" }.joined(separator: "\n")
        return "## Core production profile: \(descriptor.id.rawValue)\n\(instructions)"
    }

    private func renderEntry(
        _ library: CreativeKnowledgeLibraryV1,
        entry: CreativeKnowledgeEntryV1
    ) -> String {
        var sections = [
            "## Production library: \(library.id.rawValue)/\(entry.id.rawValue)",
            "### \(entry.title)",
            entry.outputIntent,
        ]
        if !entry.inputs.isEmpty {
            sections.append("Inputs:\n" + entry.inputs.map {
                "- \($0.role)\($0.required ? " (required)" : ""): \($0.purpose)"
            }.joined(separator: "\n"))
        }
        sections.append("Guidance:\n" + entry.guidance.map { "- \($0)" }.joined(separator: "\n"))
        sections.append("Verify:\n" + entry.verifyCriteria.map { "- \($0)" }.joined(separator: "\n"))
        if !entry.incompatibilities.isEmpty {
            sections.append("Avoid:\n" + entry.incompatibilities.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n")
    }

    private func fits(_ chunks: [String], budget: ProductionKnowledgeBudgetV1) -> Bool {
        let text = chunks.joined(separator: "\n\n")
        return text.utf8.count <= budget.maximumUTF8Bytes
            && Self.estimatedTokens(text) <= budget.maximumEstimatedTokens
    }

    public static func estimatedTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return (text.utf8.count + 3) / 4
    }
}
