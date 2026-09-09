import Foundation
import Testing
@testable import NexGenEngine

@Suite("Production style source selection")
struct ProductionStyleAdvisorTests {
    private var catalog: ProductionKnowledgeCatalogV1 {
        get throws { try EngineProductionKnowledgeResourcesV1.loadCatalog() }
    }

    @Test("genre and constraints return at most two source candidates without approving spend")
    func genreAndConstraints() throws {
        let result = try ProductionStyleAdvisorV1.recommend(
            genre: "action",
            constraints: [.complexAction, .lowRerollBudget],
            catalog: catalog
        )
        #expect(result.candidates.map(\.directorID) == [
            "director-akira-kurosawa-motion-and-weather",
            "director-paul-greengrass-chaos-verit",
        ])
        #expect(result.candidates.count == 2)
        #expect(result.candidates.allSatisfy { !$0.feelsLike.isEmpty })
        #expect(result.candidates.flatMap(\.constraintTradeoffs).contains { $0.contains("action") || $0.contains("geography") })
    }

    @Test("genre selection precedes an explicitly named style")
    func genrePrecedesName() throws {
        let result = try ProductionStyleAdvisorV1.recommend(
            genre: "action",
            namedStyles: ["Fincher"],
            catalog: catalog
        )
        #expect(result.candidates.allSatisfy { $0.kind == .genre })
        #expect(result.candidates.map(\.directorID) == [
            "director-akira-kurosawa-motion-and-weather",
            "director-paul-greengrass-chaos-verit",
        ])
    }

    @Test("two directors become alternative dominant bases with scoped synthesis")
    func directorSynthesis() throws {
        let result = try ProductionStyleAdvisorV1.recommend(
            namedStyles: ["Greengrass", "Kurosawa"], catalog: catalog
        )
        #expect(result.candidates.count == 2)
        #expect(Set(result.candidates.map(\.directorID)) == [
            "director-paul-greengrass-chaos-verit",
            "director-akira-kurosawa-motion-and-weather",
        ])
        #expect(result.candidates.allSatisfy { $0.kind == .synthesis && $0.requiresDimensionChoice })
        #expect(result.candidates.allSatisfy { $0.synthesisSourceIDs.count == 1 })
        #expect(result.candidates.allSatisfy { $0.proposedSelection == nil })
    }

    @Test("Jarmusch alias resolves as one base, one signature and scoped Ozu deviations")
    func jarmuschAlias() throws {
        let result = try ProductionStyleAdvisorV1.recommend(namedStyles: ["Jarmusch"], catalog: catalog)
        let candidate = try #require(result.candidates.first)
        let selection = try #require(candidate.proposedSelection)
        #expect(candidate.kind == .alias)
        #expect(selection.directorID == "director-wim-wenders-the-seeing-road")
        #expect(selection.signatureID == "dop-robby-m-ller")
        #expect(Set(selection.overrides.map(\.dimension)) == [.camera, .timing])
        #expect(Set(selection.overrides.compactMap(\.sourceEntryID)) == ["director-yasujir-ozu-domestic-stillness"])
        let resolved = try ResolvedProductionStyleV1.resolve(selection, catalog: catalog)
        #expect(resolved.value(.camera)?.contains("locked off") == true)
        #expect(resolved.criteria.contains { $0.source.recipeID == "director-yasujir-ozu-domestic-stillness" && $0.source.dimension == .timing })
    }

    @Test("house signatures and clashes never acquire a silent overlay")
    func pairingPolicy() throws {
        let fincher = try ProductionStyleAdvisorV1.recommend(namedStyles: ["Fincher"], catalog: catalog)
        #expect(fincher.candidates.first?.recommendedSignatureID == nil)
        #expect(fincher.candidates.first?.pairing.disposition == .embeddedHouseSignature)

        let rejected = ProductionStyleSelectionV1(
            directorID: "director-david-fincher-surgical-control",
            signatureID: "dop-emmanuel-lubezki",
            signatureDimensions: [.lighting, .color]
        )
        #expect(throws: ProductionKnowledgeErrorV1.self) {
            _ = try ResolvedProductionStyleV1.resolve(rejected, catalog: catalog)
        }
        let accepted = ProductionStyleSelectionV1(
            directorID: rejected.directorID,
            signatureID: rejected.signatureID,
            signatureDimensions: rejected.signatureDimensions,
            overrides: [
                .init(dimension: .lighting, value: "Natural light only.", reason: "User accepts the conflict with surgical control.",
                      sourceEntryID: "dop-emmanuel-lubezki", verification: .init(scope: .frame, evidenceKind: .image, criterion: "Light is visibly natural and motivated.")),
                .init(dimension: .color, value: "Naturalistic luminous grade.", reason: "User accepts the conflict with surgical control.",
                      sourceEntryID: "dop-emmanuel-lubezki", verification: .init(scope: .frame, evidenceKind: .image, criterion: "The grade remains naturalistic and luminous.")),
            ]
        )
        #expect(try ResolvedProductionStyleV1.resolve(accepted, catalog: catalog).selection == accepted)
    }

    @Test("Anderson with Storaro can replace color without replacing camera")
    func andersonStoraroColorOnly() throws {
        let recommendation = try ProductionStyleAdvisorV1.recommend(
            namedStyles: ["Wes Anderson", "Vittorio Storaro"],
            catalog: catalog
        )
        #expect(recommendation.candidates.first?.recommendedSignatureDimensions == [.color])
        let selection = ProductionStyleSelectionV1(
            directorID: "director-wes-anderson-symmetry-deadpan",
            signatureID: "dop-vittorio-storaro",
            signatureDimensions: [.color],
            overrides: [
                .init(
                    dimension: .color,
                    value: "Color changes carry the dramatic arc.",
                    reason: "Use Storaro only for the explicitly accepted color dimension.",
                    sourceEntryID: "dop-vittorio-storaro",
                    verification: .init(
                        scope: .sequence,
                        evidenceKind: .video,
                        criterion: "The planned color change is visible across the sequence."
                    )
                ),
            ]
        )
        let resolved = try ResolvedProductionStyleV1.resolve(selection, catalog: catalog)
        #expect(resolved.value(.color) == selection.overrides[0].value)
        #expect(resolved.value(.camera)?.contains("locked-off") == true)
        #expect(resolved.dimensions.first(where: { $0.dimension == .camera })?.sourceEntryID
            == selection.directorID)
    }

    @Test("known source gaps remain explicit gaps")
    func sourceGap() throws {
        let result = try ProductionStyleAdvisorV1.recommend(namedStyles: ["Michael Mann"], catalog: catalog)
        #expect(result.candidates.isEmpty)
        #expect(result.disclosure.first?.contains("No independent source recipe") == true)
    }
}
