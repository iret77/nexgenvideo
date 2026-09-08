import Foundation
import Testing
@testable import NexGenEngine

@Suite("Resolved production style")
struct ResolvedProductionStyleTests {
    @Test("every recipe's original Verify clauses have typed evidence bindings")
    func completeCriterionCoverage() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let library = try #require(catalog.library(id: "film-production-blueprints"))
        for entry in library.entries {
            let prefix = "Blueprint verification: "
            let criteria = try entry.guidance.filter { $0.hasPrefix(prefix) }.map {
                try JSONDecoder().decode(ProductionStyleCriterionV1.self, from: Data($0.dropFirst(prefix.count).utf8))
            }
            #expect(!criteria.isEmpty)
            #expect(criteria.map(\.sourceClause).joined(separator: " ") == entry.verifyCriteria.first)
            #expect(criteria.allSatisfy { $0.recipeID == entry.id.rawValue })
            if entry.id.rawValue.hasPrefix("director-") {
                let resolved = try ResolvedProductionStyleV1.resolve(.init(directorID: entry.id.rawValue), catalog: catalog)
                #expect(resolved.criteria.map(\.source) == criteria)
            }
        }
    }

    @Test("a color signature leaves the director's camera and composition intact")
    func dimensionOverride() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let director = "director-wes-anderson-symmetry-deadpan"
        let base = try ResolvedProductionStyleV1.resolve(.init(directorID: director), catalog: catalog)
        let selected = try ResolvedProductionStyleV1.resolve(.init(
            directorID: director, signatureID: "dop-vittorio-storaro", signatureDimensions: [.color],
            overrides: [.init(dimension: .color, value: "Amber intimacy shifts into cold blue isolation.",
                              reason: "Use the chosen color symbolism while retaining frontal tableaux.",
                              sourceEntryID: "dop-vittorio-storaro")]
        ), catalog: catalog)
        #expect(selected.value(.color) == "Amber intimacy shifts into cold blue isolation.")
        #expect(selected.value(.camera) == base.value(.camera))
        #expect(selected.value(.composition) == base.value(.composition))
        #expect(selected.sourceVerifyClauses[director] == base.sourceVerifyClauses[director])
        let color = try #require(selected.criteria.first { $0.source.recipeID == director && $0.source.dimension == .color })
        #expect(color.source.sourceClause.contains("pastel"))
        #expect(color.expected == "Amber intimacy shifts into cold blue isolation.")
        #expect(color.overrideReason != nil)
        #expect(selected.criteria.filter { $0.source.dimension != .color } == base.criteria.filter { $0.source.dimension != .color })
        #expect(selected.criteria.contains { $0.source.recipeID == "dop-vittorio-storaro" && $0.source.scope == .sequence })
        try selected.validate(catalog: catalog)
    }

    @Test("source criteria retain temporal and sequence scope")
    func temporalScope() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let anderson = try ResolvedProductionStyleV1.resolve(.init(directorID: "director-wes-anderson-symmetry-deadpan"), catalog: catalog)
        let hold = try #require(anderson.criteria.first { $0.source.sourceClause.contains("deadpan hold") })
        #expect(hold.source.scope == .shot)
        #expect(hold.source.evidenceKind == .video)
        let spielberg = try ResolvedProductionStyleV1.resolve(.init(directorID: "director-steven-spielberg-invisible-blockbuster-grammar"), catalog: catalog)
        let reveal = try #require(spielberg.criteria.first { $0.source.sourceClause.contains("BEFORE") })
        #expect(reveal.source.scope == .sequence)
    }

    @Test("a free-form camera override cannot inherit a static frame-only verification")
    func overrideEvidenceScope() throws {
        let style = try ResolvedProductionStyleV1.resolve(.init(
            directorID: "director-wes-anderson-symmetry-deadpan",
            overrides: [.init(dimension: .camera, value: "A slow continuous dolly approaches the subject.",
                              reason: "The approach replaces the frontal static setup.")]
        ), catalog: EngineProductionKnowledgeResourcesV1.loadCatalog())
        let camera = try #require(style.criteria.first { $0.source.dimension == .camera })
        #expect(camera.source.scope == .frame)
        #expect(camera.scope == .sequence)
        #expect(camera.evidenceKind == .video)
    }

    @Test("selecting a director never silently adds a cinematographer")
    func noImplicitSignature() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        let style = try ResolvedProductionStyleV1.resolve(
            .init(directorID: "director-david-fincher-surgical-control"), catalog: catalog
        )
        #expect(style.selection.signatureID == nil)
        #expect(style.dimensions.allSatisfy { $0.sourceEntryID == "director-david-fincher-surgical-control" })
    }

    @Test("unlabelled signature dimensions require an explicit source-bound interpretation")
    func noInventedDimension() throws {
        let catalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
        #expect(throws: ProductionKnowledgeErrorV1.self) {
            _ = try ResolvedProductionStyleV1.resolve(.init(
                directorID: "director-wes-anderson-symmetry-deadpan",
                signatureID: "dop-vittorio-storaro", signatureDimensions: [.color]
            ), catalog: catalog)
        }
    }
}
