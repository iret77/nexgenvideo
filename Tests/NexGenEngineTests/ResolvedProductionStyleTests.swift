import Testing
@testable import NexGenEngine

@Suite("Resolved production style")
struct ResolvedProductionStyleTests {
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
        try selected.validate(catalog: catalog)
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
