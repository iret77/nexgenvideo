import Foundation
import NexGenEngine

enum ProductionStyleContext {
    static func prompt(dataRoot: URL, phase: String) throws -> String? {
        guard !["project_init", "analysis", "brief"].contains(phase) else { return nil }
        let style: ResolvedProductionStyleV1?
        do {
            style = try ProductionStyleStoreV1.load(dataRoot: dataRoot)
        } catch {
            return "Production Design style is stale or unreadable. Read-only diagnosis remains available. Explain the issue and request explicit rewind to production_design before replacing or clearing style_selection. Do not generate using a stale style or silently omit it. " + error.localizedDescription
        }
        guard let style else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let resolved = String(decoding: try encoder.encode(style), as: UTF8.self)
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        guard let library = catalog.library(id: "film-production-blueprints") else {
            throw ToolError("The selected production style library is unavailable.")
        }
        let selectedIDs = Set([style.selection.directorID] + [style.selection.signatureID].compactMap { $0 }
            + style.selection.overrides.compactMap(\.sourceEntryID))
        let selectedEntries = library.entries.filter { selectedIDs.contains($0.id.rawValue) }
        let recipes = selectedEntries.map { $0.guidance.first ?? "" }.joined(separator: "\n")
        let procedures = phase == "production_design" ? (selectedEntries.first?.guidance.filter {
            $0.hasPrefix("Selection and synthesis procedure:") || $0.hasPrefix("Pairing procedure:")
        }.joined(separator: "\n") ?? "") : "Selection procedures remain available through get_production_knowledge when an explicit style revision is requested."
        return """
        Project production style for \(phase):
        \(resolved)
        Complete selected source recipes (declared dimension overrides govern conflicting source suggestions):
        \(recipes)
        Governing selection and combination procedures:
        \(procedures)
        Apply composition and camera to setups and shot coverage; lighting and color to visual references and finish; editing and timing to actual cut relations and ranges. Choose one concrete camera action per shot. Sound guidance is subordinate to the project's approved audio ownership; Musicvideo retains its original song. Keep temporal, sequence, and audio criteria attached to the corresponding media evidence. A still cannot verify a camera move, hold, cut order, or sound. Unobserved criteria remain not_observed. Production Design approval owns this style; changing it requires the normal explicit rewind and approval.
        """
    }
}
