import Foundation
import NexGenEngine

enum PipelineProductionKnowledgeContext {
    static func append(to original: String, dataRoot: URL, phase: String, packName: String) throws -> String {
        var prompt = original
        let registry = PackCatalog.registry(activePack: packName)
        let consumers = try ProductionKnowledgeConsumerRegistryV1(
            registrations: registry.productionKnowledgeConsumers
        )
        guard let registration = consumers.registration(for: packName) else {
            return prompt
        }
        let productionKnowledgeCatalog: ProductionKnowledgeCatalogV1
        do {
            productionKnowledgeCatalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
            try consumers.validateResources(in: productionKnowledgeCatalog)
        } catch {
            Log.agent.error(
                "production knowledge unavailable error=\(error.localizedDescription)"
            )
            throw ToolError(
                "NexGenVideo's production knowledge is damaged. Reinstall the app."
            )
        }
        let descriptor = registration.descriptor
        let metadata: ProductionKnowledgeActivationMetadataV1
        do {
            metadata = try registration.metadataProvider(dataRoot, phase)
        } catch let blocked as GateBlocked {
            throw ToolError(blocked.message)
        } catch {
            throw ToolError(
                "The \(packName) production-knowledge activation metadata is unavailable: "
                    + error.localizedDescription
            )
        }
        let activeProfiles = Set(
            registry.activeProductionProfileIDs(metadata: metadata.values).map {
                ProductionProfileDescriptorIDV1(rawValue: $0.rawValue)
            }
        )
        let undeclaredProfiles = activeProfiles.subtracting(descriptor.profileResourceIDs)
        guard undeclaredProfiles.isEmpty else {
            throw ToolError(
                "The \(packName) production-knowledge descriptor does not declare active profiles: "
                    + undeclaredProfiles.map(\.rawValue).sorted().joined(separator: ", ")
            )
        }
        let selection = descriptor.selection(for: phase)
        let declaredLibraries = Set(selection?.libraryIDs ?? [])
        let activeLibraries: Set<CreativeKnowledgeLibraryIDV1>
        if let requested = metadata.activeLibraryIDs {
            let undeclaredLibraries = requested.subtracting(declaredLibraries)
            guard undeclaredLibraries.isEmpty else {
                throw ToolError(
                    "The \(packName) activation metadata requested undeclared production libraries: "
                        + undeclaredLibraries.map(\.rawValue).sorted().joined(separator: ", ")
                )
            }
            activeLibraries = requested
        } else {
            activeLibraries = declaredLibraries
        }
        let preferredLibraryOrder = (selection?.libraryIDs ?? []).filter {
            activeLibraries.contains($0)
        }
        let assembly = try ProductionKnowledgeContextAssemblerV1(
            catalog: productionKnowledgeCatalog,
            predicates: ProductionMachinePredicateRegistryV1.standard()
        ).assemble(
            ProductionKnowledgeAssemblyQueryV1(
                packID: packName,
                phase: selection?.knowledgePhase ?? phase,
                intentTags: metadata.intentTags.union(selection?.intentTags ?? []),
                activeProfileIDs: activeProfiles,
                activeLibraryIDs: activeLibraries,
                budget: descriptor.budget
            ),
            preferredLibraryOrder: preferredLibraryOrder
        )
        if !assembly.prompt.isEmpty {
            prompt += "\n\nFollow this selected core production knowledge:\n\n\(assembly.prompt)"
        }
        if !assembly.omittedLibraryEntryIDs.isEmpty {
            prompt += "\n\nAdditional selected guidance is available through get_production_knowledge(operation: read, entryID: ...). Retrieve complete applicable entries before using them: "
                + assembly.omittedLibraryEntryIDs.joined(separator: ", ")
            Log.agent.warning(
                "production knowledge budget omitted="
                    + assembly.omittedLibraryEntryIDs.joined(separator: ",")
                    + " bytes=\(assembly.utf8Bytes) tokens=\(assembly.estimatedTokens)"
            )
        }
        return prompt
    }
}
