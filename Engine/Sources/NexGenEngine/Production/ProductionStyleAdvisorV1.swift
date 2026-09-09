import Foundation

public enum ProductionStyleConstraintV1: String, Codable, Sendable, CaseIterable {
    case lowRerollBudget = "low_reroll_budget"
    case complexAction = "complex_action"
    case dialogueHeavy = "dialogue_heavy"
    case facePerformance = "face_performance"
    case highContinuityRisk = "high_continuity_risk"
    case stylizedAnimation = "stylized_animation"
}

public enum ProductionStyleRecommendationKindV1: String, Codable, Sendable {
    case explicit
    case alias
    case nearestMatch = "nearest_match"
    case genre
    case mood
    case synthesis
}

public enum ProductionStylePairingDispositionV1: String, Codable, Sendable {
    case none
    case embeddedHouseSignature = "embedded_house_signature"
    case documented
    case crossPairing = "cross_pairing"
    case clash
    case unlisted
}

public struct ProductionStylePairingAssessmentV1: Codable, Sendable, Equatable {
    public let disposition: ProductionStylePairingDispositionV1
    public let explanation: String
    public let requiresExplicitTradeoffAcceptance: Bool
}

public struct ProductionStyleCandidateV1: Codable, Sendable, Equatable {
    public let kind: ProductionStyleRecommendationKindV1
    public let directorID: String
    public let recommendedSignatureID: String?
    public let recommendedSignatureDimensions: [ProductionStyleDimensionV1]
    public let pairing: ProductionStylePairingAssessmentV1
    public let feelsLike: String
    public let rationale: String
    public let constraintTradeoffs: [String]
    public let synthesisSourceIDs: [String]
    public let proposedSelection: ProductionStyleSelectionV1?
    public let requiresDimensionChoice: Bool
}

public struct ProductionStyleRecommendationV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "production-style-recommendation/v1"

    public let schema: String
    public let libraryVersion: String
    public let candidates: [ProductionStyleCandidateV1]
    public let clarification: [String]
    public let disclosure: [String]
}

public enum ProductionStyleAdvisorV1 {
    private struct AliasRecipe {
        let match: (String) -> Bool
        let directorID: String
        let signatureID: String?
        let signatureDimensions: [ProductionStyleDimensionV1]
        let overrideSources: [(ProductionStyleDimensionV1, String)]
        let rationale: String
    }

    private static let houseSignatures: Set<String> = [
        "director-stanley-kubrick-one-point-dread",
        "director-quentin-tarantino-pulp-tension",
        "director-david-fincher-surgical-control",
        "director-martin-scorsese-guilty-momentum",
        "director-ridley-scott-layered-atmosphere",
        "director-edgar-wright-comedy-in-the-cut",
        "director-wachowskis-bill-pope-digital-baroque",
        "director-vince-gilligan-procedural-corrosion",
    ]

    private static let documentedPairs: [String: Set<String>] = [
        "director-steven-spielberg-invisible-blockbuster-grammar": ["dop-janusz-kami-ski"],
        "director-christopher-nolan-engineered-time": ["dop-hoyte-van-hoytema"],
        "director-denis-villeneuve-slow-monumental-dread": ["dop-greig-fraser"],
        "director-wong-kar-wai-romantic-blur": ["dop-christopher-doyle"],
        "director-ingmar-bergman-the-face-as-landscape": ["dop-sven-nykvist"],
        "director-woody-allen-lineage-master-shot-talk-comedy": ["dop-gordon-willis"],
        "director-c-line-sciamma-the-exchanged-gaze": ["dop-claire-mathon"],
        "director-terrence-malick-whispered-creation": ["dop-emmanuel-lubezki"],
        "director-wim-wenders-the-seeing-road": ["dop-robby-m-ller"],
    ]

    private static let crossPairs: [String: Set<String>] = [
        "director-alfred-hitchcock-pure-suspense-grammar": ["dop-gordon-willis"],
        "director-sergio-leone-opera-of-faces": ["dop-vittorio-storaro"],
        "director-danny-boyle-kinetic-euphoria": ["dop-christopher-doyle"],
        "director-yasujir-ozu-domestic-stillness": ["dop-sven-nykvist"],
        "director-david-lynch-dream-logic": ["dop-bradford-young"],
        "director-andrei-tarkovsky-sculpting-in-time": ["dop-greig-fraser"],
        "director-paul-greengrass-chaos-verit": ["dop-janusz-kami-ski"],
        "director-vince-gilligan-procedural-corrosion": ["dop-greig-fraser"],
        "director-akira-kurosawa-motion-and-weather": ["dop-janusz-kami-ski"],
        "director-wes-anderson-symmetry-deadpan": ["dop-vittorio-storaro"],
    ]

    private static let clashes: [String: Set<String>] = [
        "director-david-fincher-surgical-control": ["dop-emmanuel-lubezki"],
        "director-stanley-kubrick-one-point-dread": ["dop-emmanuel-lubezki"],
        "director-paul-greengrass-chaos-verit": ["dop-vittorio-storaro"],
        "director-ugc-found-footage-authorless-camera": ["dop-vittorio-storaro"],
        "director-hayao-miyazaki-ghibli-animated-humanism": ["dop-gordon-willis"],
        "director-christopher-nolan-engineered-time": ["dop-christopher-doyle"],
    ]

    private static let defaultSignatures: [String: String] = [
        "director-steven-spielberg-invisible-blockbuster-grammar": "dop-janusz-kami-ski",
        "director-christopher-nolan-engineered-time": "dop-hoyte-van-hoytema",
        "director-denis-villeneuve-slow-monumental-dread": "dop-greig-fraser",
        "director-wong-kar-wai-romantic-blur": "dop-christopher-doyle",
        "director-ingmar-bergman-the-face-as-landscape": "dop-sven-nykvist",
        "director-woody-allen-lineage-master-shot-talk-comedy": "dop-gordon-willis",
        "director-c-line-sciamma-the-exchanged-gaze": "dop-claire-mathon",
        "director-terrence-malick-whispered-creation": "dop-emmanuel-lubezki",
        "director-wim-wenders-the-seeing-road": "dop-robby-m-ller",
    ]

    private static let genreShortlists: [String: [String]] = [
        "action": ["director-akira-kurosawa-motion-and-weather", "director-paul-greengrass-chaos-verit"],
        "spy espionage": ["director-david-fincher-surgical-control", "director-christopher-nolan-engineered-time"],
        "horror": ["director-stanley-kubrick-one-point-dread", "director-david-lynch-dream-logic"],
        "thriller": ["director-david-fincher-surgical-control", "director-alfred-hitchcock-pure-suspense-grammar"],
        "crime krimi": ["director-david-fincher-surgical-control", "director-vince-gilligan-procedural-corrosion"],
        "drama": ["director-ingmar-bergman-the-face-as-landscape", "director-yasujir-ozu-domestic-stillness"],
        "comedy": ["director-wes-anderson-symmetry-deadpan", "director-zaz-mel-brooks-parody-deadpan"],
        "biopic": ["director-steven-spielberg-invisible-blockbuster-grammar", "director-david-fincher-surgical-control"],
        "documentary": ["director-wim-wenders-the-seeing-road", "director-paul-greengrass-chaos-verit"],
        "anime": ["director-hayao-miyazaki-ghibli-animated-humanism", "director-sergio-leone-opera-of-faces"],
        "family animation": ["director-steven-spielberg-invisible-blockbuster-grammar", "director-hayao-miyazaki-ghibli-animated-humanism"],
        "music film musical music video": ["director-danny-boyle-kinetic-euphoria", "director-wong-kar-wai-romantic-blur"],
        "commercial ad": ["director-ridley-scott-layered-atmosphere", "director-wes-anderson-symmetry-deadpan"],
    ]

    private static let moodShortlists: [(signals: [String], ids: [String])] = [
        (["epic", "vast", "monumental", "sublime"], ["director-denis-villeneuve-slow-monumental-dread", "director-roger-deakins-lineage-dop-grammar-mendes-class"]),
        (["dread", "slow burn", "oppressive", "uncanny"], ["director-stanley-kubrick-one-point-dread", "director-david-lynch-dream-logic"]),
        (["wonder", "warm", "family", "adventure"], ["director-steven-spielberg-invisible-blockbuster-grammar", "director-hayao-miyazaki-ghibli-animated-humanism"]),
        (["whimsical", "deadpan", "storybook"], ["director-wes-anderson-symmetry-deadpan"]),
        (["raw", "real", "urgent", "found"], ["director-paul-greengrass-chaos-verit", "director-ugc-found-footage-authorless-camera"]),
        (["cold", "controlled", "precise", "paranoid"], ["director-david-fincher-surgical-control", "director-alfred-hitchcock-pure-suspense-grammar"]),
        (["romantic", "longing", "memory of love"], ["director-wong-kar-wai-romantic-blur", "director-terrence-malick-whispered-creation"]),
        (["quiet", "observational", "on the road"], ["director-wim-wenders-the-seeing-road", "director-yasujir-ozu-domestic-stillness"]),
        (["spiritual", "dreamlike", "grief", "faith"], ["director-andrei-tarkovsky-sculpting-in-time", "director-terrence-malick-whispered-creation"]),
        (["intimate", "face driven", "confessional"], ["director-ingmar-bergman-the-face-as-landscape", "director-yasujir-ozu-domestic-stillness"]),
        (["kinetic", "euphoric", "music driven"], ["director-danny-boyle-kinetic-euphoria"]),
        (["mythic", "operatic", "standoff"], ["director-sergio-leone-opera-of-faces"]),
        (["pulpy", "talky menace", "genre homage"], ["director-quentin-tarantino-pulp-tension"]),
        (["methodical", "corrosive", "consequence"], ["director-vince-gilligan-procedural-corrosion", "director-david-fincher-surgical-control"]),
        (["spoof", "absurd", "silly"], ["director-zaz-mel-brooks-parody-deadpan"]),
        (["witty", "verbal", "neurotic", "urbane"], ["director-woody-allen-lineage-master-shot-talk-comedy", "director-wes-anderson-symmetry-deadpan"]),
        (["gag precise", "beat synced", "genre blend comedy"], ["director-edgar-wright-comedy-in-the-cut"]),
        (["dynamic", "elemental", "ensemble motion"], ["director-akira-kurosawa-motion-and-weather"]),
        (["tender desire", "exchanged gaze"], ["director-c-line-sciamma-the-exchanged-gaze", "director-wong-kar-wai-romantic-blur"]),
        (["unvarnished", "precarious", "lived in"], ["director-dardenne-arnold-social-realism"]),
        (["sleek", "techno noir", "simulated worlds"], ["director-wachowskis-bill-pope-digital-baroque"]),
        (["propulsive", "seductive", "rise and fall"], ["director-martin-scorsese-guilty-momentum", "director-danny-boyle-kinetic-euphoria"]),
        (["dense", "breathable worlds", "atmosphere"], ["director-ridley-scott-layered-atmosphere", "director-denis-villeneuve-slow-monumental-dread"]),
    ]

    private static let unresolvedSourceGaps = ["bong joon ho", "michael mann", "polanski", "herzog", "apartment paranoia"]

    public static func pairing(directorID: String, signatureID: String?) -> ProductionStylePairingAssessmentV1 {
        guard let signatureID else {
            if houseSignatures.contains(directorID) {
                return .init(disposition: .embeddedHouseSignature,
                             explanation: "The source recipe already owns its image grammar; no additional DoP package is applied.",
                             requiresExplicitTradeoffAcceptance: false)
            }
            return .init(disposition: .none, explanation: "No DoP signature selected.", requiresExplicitTradeoffAcceptance: false)
        }
        if clashes[directorID]?.contains(signatureID) == true {
            return .init(disposition: .clash,
                         explanation: clashExplanation(directorID: directorID, signatureID: signatureID),
                         requiresExplicitTradeoffAcceptance: true)
        }
        if houseSignatures.contains(directorID) {
            return .init(disposition: .embeddedHouseSignature,
                         explanation: "This director recipe has a complete house image grammar. An extra signature can dilute it and needs an explicit dimension-by-dimension decision.",
                         requiresExplicitTradeoffAcceptance: true)
        }
        if documentedPairs[directorID]?.contains(signatureID) == true {
            return .init(disposition: .documented, explanation: "Documented source partnership.", requiresExplicitTradeoffAcceptance: false)
        }
        if crossPairs[directorID]?.contains(signatureID) == true {
            return .init(disposition: .crossPairing, explanation: "Documented coherent experimental cross-pairing.", requiresExplicitTradeoffAcceptance: false)
        }
        return .init(disposition: .unlisted,
                     explanation: "The source harmony map does not list this pairing. Keep the director dominant and explain every selected signature dimension.",
                     requiresExplicitTradeoffAcceptance: true)
    }

    public static func validateCombination(_ selection: ProductionStyleSelectionV1) throws {
        let secondaryDirectors = Set(selection.overrides.compactMap { override -> String? in
            guard let source = override.sourceEntryID,
                  source.hasPrefix("director-"), source != selection.directorID else { return nil }
            return source
        })
        guard secondaryDirectors.count <= 1 else {
            throw invalid("A synthesis may use only one secondary director and must keep one dominant base.")
        }
        guard selection.overrides.allSatisfy({ override in
            guard let source = override.sourceEntryID, source.hasPrefix("dop-") else { return true }
            return source == selection.signatureID
        }) else {
            throw invalid("A style may use only its one declared DoP signature.")
        }
        let assessment = pairing(directorID: selection.directorID, signatureID: selection.signatureID)
        guard assessment.requiresExplicitTradeoffAcceptance else { return }
        let accepted = Set(selection.overrides.compactMap { override in
            override.sourceEntryID == selection.signatureID ? override.dimension : nil
        })
        guard Set(selection.signatureDimensions).isSubset(of: accepted) else {
            throw invalid("This pairing needs a reasoned override for every selected DoP dimension: " + assessment.explanation)
        }
    }

    public static func recommend(
        genre: String? = nil,
        namedStyles: [String] = [],
        moods: [String] = [],
        constraints: [ProductionStyleConstraintV1] = [],
        catalog: ProductionKnowledgeCatalogV1
    ) throws -> ProductionStyleRecommendationV1 {
        guard let library = catalog.library(id: "film-production-blueprints") else {
            throw ProductionKnowledgeErrorV1.missingResource("film-production-blueprints")
        }
        let directors = library.entries.filter { $0.id.rawValue.hasPrefix("director-") }
        if let genre, let ids = matchedValues(normalize(genre), table: genreShortlists) {
            return result(library: library, candidates: try ids.prefix(2).map {
                try makeCandidate(kind: .genre, directorID: $0, signatureID: defaultSignatures[$0],
                                  rationale: "Source genre-baseline shortlist for \(genre).", constraints: constraints,
                                  synthesisSources: [], proposedSelection: nil, library: library)
            }, clarification: [], disclosure: [])
        }
        let names = namedStyles.map(normalize).filter { !$0.isEmpty }
        let joinedNames = names.joined(separator: " ")
        if let gap = unresolvedSourceGaps.first(where: { joinedNames.contains($0) }) {
            return result(library: library, candidates: [], clarification: [],
                          disclosure: ["No independent source recipe exists for \(gap). Do not fabricate one; ask for a named available basis or explicit dimension synthesis."])
        }
        if joinedNames.contains("pixar") {
            let ids = genreShortlists["family animation"] ?? []
            let candidates = try ids.map {
                try makeCandidate(kind: .genre, directorID: $0, signatureID: defaultSignatures[$0],
                                  rationale: "Choose a director structure; Pixar remains a pointer to the complete stylized-3D method rather than a fabricated director recipe.",
                                  constraints: constraints, synthesisSources: [], proposedSelection: nil, library: library)
            }
            return result(library: library, candidates: candidates, clarification: [],
                          disclosure: ["Apply the complete pixar-look knowledge entry as the visual method after choosing a director structure."])
        }
        if joinedNames.contains("coppola") && !joinedNames.contains("godfather") && !joinedNames.contains("apocalypse") {
            let aliases = try ["coppola godfather", "coppola apocalypse"].compactMap { query -> ProductionStyleCandidateV1? in
                guard let alias = try aliasRecipe(for: query) else { return nil }
                return try makeCandidate(kind: .alias, directorID: alias.directorID,
                                         signatureID: alias.signatureID, rationale: alias.rationale,
                                         constraints: constraints, synthesisSources: alias.overrideSources.map(\.1),
                                         proposedSelection: try aliasSelection(alias, catalog: catalog), library: library)
            }
            return result(library: library, candidates: aliases,
                          clarification: ["Choose the Godfather or Apocalypse Now register."],
                          disclosure: ["Coppola is covered by two disclosed source aliases, not an invented independent recipe."])
        }
        if let alias = try aliasRecipe(for: joinedNames) {
            let candidate = try makeCandidate(kind: .alias, directorID: alias.directorID,
                                              signatureID: alias.signatureID, rationale: alias.rationale,
                                              constraints: constraints, synthesisSources: alias.overrideSources.map(\.1),
                                              proposedSelection: try aliasSelection(alias, catalog: catalog), library: library)
            return result(library: library, candidates: [candidate], clarification: [],
                          disclosure: ["The named style is a disclosed source alias compiled as one director base, at most one DoP signature, and scoped dimension overrides."])
        }
        let namedEntries = names.compactMap { name in bestNamedMatch(name, entries: library.entries) }
        let namedDirectors = unique(namedEntries.filter { $0.id.rawValue.hasPrefix("director-") })
        let namedSignatures = unique(namedEntries.filter { $0.id.rawValue.hasPrefix("dop-") })
        if namedDirectors.count >= 2 {
            let pair = Array(namedDirectors.prefix(2))
            let clash = directorClash(pair[0].id.rawValue, pair[1].id.rawValue)
            let candidates = try pair.enumerated().map { index, base in
                let source = pair[1 - index]
                return try makeCandidate(kind: .synthesis, directorID: base.id.rawValue,
                                         signatureID: nil,
                                         rationale: "Use \(base.title) as the single dominant base and choose only the dimensions that \(source.title) replaces." + (clash.map { " Source clash: " + $0 } ?? ""),
                                         constraints: constraints, synthesisSources: [source.id.rawValue],
                                         proposedSelection: nil, requiresDimensionChoice: true, library: library)
            }
            return result(library: library, candidates: candidates, clarification: ["Choose the dominant director, then approve the second director's deviations dimension by dimension."], disclosure: clash.map { [$0] } ?? [])
        }
        if let director = namedDirectors.first {
            let signature = namedSignatures.first?.id.rawValue ?? defaultSignatures[director.id.rawValue]
            let candidate = try makeCandidate(kind: .explicit, directorID: director.id.rawValue,
                                              signatureID: signature,
                                              rationale: namedSignatures.isEmpty ? "Explicit listed director recipe." : "Explicit director and DoP selection.",
                                              constraints: constraints, synthesisSources: [], proposedSelection: nil,
                                              library: library)
            return result(library: library, candidates: [candidate], clarification: [], disclosure: [])
        }
        if let signature = namedSignatures.first {
            let paired = documentedPairs.compactMap { key, value in value.contains(signature.id.rawValue) ? key : nil }.sorted()
            let candidates = try paired.prefix(2).map {
                try makeCandidate(kind: .explicit, directorID: $0, signatureID: signature.id.rawValue,
                                  rationale: "Documented director structure for the explicitly named DoP signature.",
                                  constraints: constraints, synthesisSources: [], proposedSelection: nil, library: library)
            }
            return result(library: library, candidates: candidates,
                          clarification: candidates.isEmpty ? ["Choose a director base for the named DoP signature."] : [], disclosure: [])
        }
        if !names.isEmpty, let nearest = nearestEntry(names.joined(separator: " "), entries: directors) {
            let candidate = try makeCandidate(kind: .nearestMatch, directorID: nearest.id.rawValue,
                                              signatureID: defaultSignatures[nearest.id.rawValue],
                                              rationale: "No exact recipe was found. This is the disclosed nearest local package; confirm it or request dimension synthesis.",
                                              constraints: constraints, synthesisSources: [], proposedSelection: nil, library: library)
            return result(library: library, candidates: [candidate], clarification: ["Confirm the disclosed nearest match."], disclosure: [])
        }
        let moodText = normalize(moods.joined(separator: " "))
        if !moodText.isEmpty,
           let ids = moodShortlists.first(where: { row in row.signals.contains(where: moodText.contains) })?.ids {
            return result(library: library, candidates: try ids.prefix(2).map {
                try makeCandidate(kind: .mood, directorID: $0, signatureID: defaultSignatures[$0],
                                  rationale: "Source mood-table candidate.", constraints: constraints,
                                  synthesisSources: [], proposedSelection: nil, library: library)
            }, clarification: [], disclosure: [])
        }
        return result(library: library, candidates: [],
                      clarification: ["What should it feel like in one phrase?", "Should the rhythm feel fast or slow?", "Should the world feel real or stylized?"],
                      disclosure: [])
    }

    private static func aliasRecipe(for query: String) throws -> AliasRecipe? {
        guard !query.isEmpty else { return nil }
        let aliases = [
            AliasRecipe(match: { $0.contains("coppola") && $0.contains("godfather") },
                        directorID: "director-sergio-leone-opera-of-faces", signatureID: "dop-gordon-willis",
                        signatureDimensions: [.lighting, .color], overrideSources: [(.editing, "director-alfred-hitchcock-pure-suspense-grammar")],
                        rationale: "Godfather-register Coppola alias: Leone opera timing, Willis power geometry and darkness, with ritual cross-cutting as a scoped editing deviation."),
            AliasRecipe(match: { $0.contains("coppola") && $0.contains("apocalypse") },
                        directorID: "director-terrence-malick-whispered-creation", signatureID: "dop-vittorio-storaro",
                        signatureDimensions: [.lighting, .color], overrideSources: [],
                        rationale: "Apocalypse Now-register Coppola alias: Malick's elliptical voice-over journey with Storaro color ideology."),
            AliasRecipe(match: { $0.contains("cameron") },
                        directorID: "director-steven-spielberg-invisible-blockbuster-grammar", signatureID: "dop-hoyte-van-hoytema",
                        signatureDimensions: [.lighting, .color], overrideSources: [],
                        rationale: "Cameron alias: Spielberg action geography with Hoytema steel-blue technological scale; preserve the map across every cut."),
            AliasRecipe(match: { $0.contains("jarmusch") },
                        directorID: "director-wim-wenders-the-seeing-road", signatureID: "dop-robby-m-ller",
                        signatureDimensions: [.lighting, .color],
                        overrideSources: [(.camera, "director-yasujir-ozu-domestic-stillness"), (.timing, "director-yasujir-ozu-domestic-stillness")],
                        rationale: "Jarmusch alias: Wenders structure, Müller available-light signature, and Ozu statics as two scoped deviations; it remains one dominant package."),
        ]
        if query == "coppola" || (query.contains("coppola") && !query.contains("godfather") && !query.contains("apocalypse")) {
            return nil
        }
        return aliases.first { $0.match(query) }
    }

    private static func aliasSelection(_ alias: AliasRecipe, catalog: ProductionKnowledgeCatalogV1) throws -> ProductionStyleSelectionV1 {
        var overrides = try alias.overrideSources.map { dimension, sourceID in
            let source = try entry(sourceID, catalog: catalog)
            let value = try dimensionValue(dimension, entry: source)
            let criterion = try verification(dimension, entry: source)
            return ProductionStyleOverrideV1(dimension: dimension, value: value, reason: alias.rationale,
                                             sourceEntryID: sourceID, verification: criterion)
        }
        let assessment = pairing(directorID: alias.directorID, signatureID: alias.signatureID)
        if let signatureID = alias.signatureID {
            let source = try entry(signatureID, catalog: catalog)
            overrides += try alias.signatureDimensions.compactMap { dimension in
                let needsExplicitValue: Bool
                do {
                    _ = try dimensionValue(dimension, entry: source)
                    needsExplicitValue = assessment.requiresExplicitTradeoffAcceptance
                } catch {
                    needsExplicitValue = true
                }
                guard needsExplicitValue else { return nil }
                let value: String
                if let dimensionValue = try? dimensionValue(
                    dimension,
                    entry: source
                ) {
                    value = dimensionValue
                } else {
                    value = try dimensionValue(.character, entry: source)
                }
                let criterion = try verification(dimension, entry: source)
                return ProductionStyleOverrideV1(dimension: dimension, value: value, reason: alias.rationale,
                                                 sourceEntryID: signatureID, verification: criterion)
            }
        }
        return .init(directorID: alias.directorID, signatureID: alias.signatureID,
                     signatureDimensions: alias.signatureDimensions, overrides: overrides)
    }

    private static func makeCandidate(
        kind: ProductionStyleRecommendationKindV1,
        directorID: String,
        signatureID: String?,
        rationale: String,
        constraints: [ProductionStyleConstraintV1],
        synthesisSources: [String],
        proposedSelection: ProductionStyleSelectionV1?,
        requiresDimensionChoice: Bool = false,
        library: CreativeKnowledgeLibraryV1
    ) throws -> ProductionStyleCandidateV1 {
        guard let entry = library.entries.first(where: { $0.id.rawValue == directorID }) else {
            throw invalid("Unknown director blueprint: \(directorID)")
        }
        let character = entry.guidance.first(where: { $0.hasPrefix("Blueprint dimension character:") })?
            .replacingOccurrences(of: "Blueprint dimension character:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? entry.title
        return .init(kind: kind, directorID: directorID, recommendedSignatureID: signatureID,
                     recommendedSignatureDimensions: recommendedSignatureDimensions(
                        directorID: directorID,
                        signatureID: signatureID
                     ),
                     pairing: pairing(directorID: directorID, signatureID: signatureID),
                     feelsLike: character, rationale: rationale,
                     constraintTradeoffs: constraints.compactMap { tradeoff($0, directorID: directorID, signatureID: signatureID) },
                     synthesisSourceIDs: uniqueStrings(synthesisSources), proposedSelection: proposedSelection,
                     requiresDimensionChoice: requiresDimensionChoice)
    }

    private static func recommendedSignatureDimensions(
        directorID: String,
        signatureID: String?
    ) -> [ProductionStyleDimensionV1] {
        guard let signatureID else { return [] }
        if directorID == "director-wes-anderson-symmetry-deadpan",
           signatureID == "dop-vittorio-storaro" {
            return [.color]
        }
        return [.lighting, .color]
    }

    private static func tradeoff(_ constraint: ProductionStyleConstraintV1, directorID: String, signatureID: String?) -> String? {
        let ids = Set([directorID] + [signatureID].compactMap { $0 })
        switch constraint {
        case .lowRerollBudget:
            if !ids.isDisjoint(with: ["director-terrence-malick-whispered-creation", "director-danny-boyle-kinetic-euphoria", "director-yasujir-ozu-domestic-stillness", "director-vince-gilligan-procedural-corrosion"]) { return "Favors the low-reroll production pattern in this package." }
            if !ids.isDisjoint(with: ["director-andrei-tarkovsky-sculpting-in-time", "dop-emmanuel-lubezki"]) { return "Long coherent takes and extension chains conflict with a low reroll budget; style approval does not approve that spend." }
        case .complexAction:
            if !ids.isDisjoint(with: ["director-paul-greengrass-chaos-verit", "director-ugc-found-footage-authorless-camera", "director-david-lynch-dream-logic", "director-akira-kurosawa-motion-and-weather"]) { return "The package can absorb complex action artifacts or preserve crowd geography." }
            if !ids.isDisjoint(with: ["director-david-fincher-surgical-control", "director-stanley-kubrick-one-point-dread"]) { return "Surgical framing exposes physics and continuity failures in complex action." }
        case .dialogueHeavy:
            if !ids.isDisjoint(with: ["director-yasujir-ozu-domestic-stillness", "director-quentin-tarantino-pulp-tension", "director-ingmar-bergman-the-face-as-landscape"]) { return "The package favors dialogue coverage." }
            if ids.contains("director-paul-greengrass-chaos-verit") { return "Verité dialogue coverage can consume many takes." }
        case .facePerformance:
            if !ids.isDisjoint(with: ["director-ingmar-bergman-the-face-as-landscape", "dop-sven-nykvist"]) { return "The package protects face performance; reserve performance rerolls for the actual peaks." }
            if ids.contains("dop-gordon-willis") { return "Buried eyes conflict with readable face performance." }
        case .highContinuityRisk:
            if !ids.isDisjoint(with: ["director-terrence-malick-whispered-creation", "director-david-lynch-dream-logic"]) { return "Elliptical or dream logic tolerates visible continuity jumps." }
            if ids.contains("director-christopher-nolan-engineered-time") { return "Parallel timelines amplify continuity mistakes." }
        case .stylizedAnimation:
            if !ids.isDisjoint(with: ["director-hayao-miyazaki-ghibli-animated-humanism", "director-wes-anderson-symmetry-deadpan"]) { return "The package favors a readable stylized world." }
            if !ids.isDisjoint(with: ["dop-greig-fraser", "dop-gordon-willis"]) { return "Deep underexposure conflicts with readable-face warmth in stylized animation." }
        }
        return nil
    }

    private static func clashExplanation(directorID: String, signatureID: String) -> String {
        switch (directorID, signatureID) {
        case ("director-david-fincher-surgical-control", "dop-emmanuel-lubezki"),
             ("director-stanley-kubrick-one-point-dread", "dop-emmanuel-lubezki"):
            return "Lubezki natural-light flow conflicts with surgical control."
        case ("director-paul-greengrass-chaos-verit", "dop-vittorio-storaro"),
             ("director-ugc-found-footage-authorless-camera", "dop-vittorio-storaro"):
            return "Storaro theatrical color conflicts with found verité logic."
        case ("director-hayao-miyazaki-ghibli-animated-humanism", "dop-gordon-willis"):
            return "Willis darkness conflicts with readable family warmth."
        case ("director-christopher-nolan-engineered-time", "dop-christopher-doyle"):
            return "Doyle motion smear conflicts with the mechanism's legibility."
        default:
            return "The source clash table marks these packages as contradictory."
        }
    }

    private static func directorClash(_ first: String, _ second: String) -> String? {
        let pair = Set([first, second])
        if pair == ["director-ridley-scott-layered-atmosphere", "director-dardenne-arnold-social-realism"] {
            return "Scott atmosphere layering conflicts with Dardenne/Arnold anti-gloss; choose which dimensions remain dominant instead of combining both packages."
        }
        return nil
    }

    private static func bestNamedMatch(_ query: String, entries: [CreativeKnowledgeEntryV1]) -> CreativeKnowledgeEntryV1? {
        entries.first { entry in
            let title = normalize(entry.title)
            let id = normalize(entry.id.rawValue.replacingOccurrences(of: "director-", with: "").replacingOccurrences(of: "dop-", with: ""))
            return title == query || title.contains(query) || query.contains(title) || id.hasPrefix(query)
        }
    }

    private static func nearestEntry(_ query: String, entries: [CreativeKnowledgeEntryV1]) -> CreativeKnowledgeEntryV1? {
        let queryTokens = Set(query.split(separator: " ").map(String.init).filter { $0.count > 2 })
        guard !queryTokens.isEmpty else { return nil }
        let ranked = entries.map { entry -> (Int, CreativeKnowledgeEntryV1) in
            let searchableText = entry.title + " " + entry.applicability.intentTags.joined(separator: " ")
            let normalizedWords = normalize(searchableText).split(separator: " ").map(String.init)
            let words = Set(normalizedWords)
            let score = queryTokens.intersection(words).count
            return (score, entry)
        }.sorted { left, right in
            if left.0 == right.0 {
                return left.1.id.rawValue < right.1.id.rawValue
            }
            return left.0 > right.0
        }
        return (ranked.first?.0 ?? 0) > 0 ? ranked.first?.1 : nil
    }

    private static func matchedValues(_ query: String, table: [String: [String]]) -> [String]? {
        table.sorted { $0.key.count > $1.key.count }.first { key, _ in
            key.split(separator: " ").contains { query.contains($0) }
        }?.value
    }

    private static func entry(_ id: String, catalog: ProductionKnowledgeCatalogV1) throws -> CreativeKnowledgeEntryV1 {
        guard let value = catalog.library(id: "film-production-blueprints")?.entries.first(where: { $0.id.rawValue == id }) else {
            throw invalid("Unknown blueprint: \(id)")
        }
        return value
    }

    private static func dimensionValue(_ dimension: ProductionStyleDimensionV1, entry: CreativeKnowledgeEntryV1) throws -> String {
        let labels: [ProductionStyleDimensionV1: [String]] = [
            .character: ["character"], .composition: ["Composition"], .camera: ["Camera"],
            .editing: ["Editing"], .lighting: ["Light", "Light/Color"], .color: ["Color", "Grade", "Light/Color"],
            .timing: ["Timing"], .sound: ["Sound"],
        ]
        for label in labels[dimension] ?? [] {
            let prefix = "Blueprint dimension \(label):"
            if let value = entry.guidance.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count) {
                let trimmed = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        throw invalid("Blueprint \(entry.id.rawValue) has no source dimension \(dimension.rawValue).")
    }

    private static func verification(_ dimension: ProductionStyleDimensionV1, entry: CreativeKnowledgeEntryV1) throws -> ProductionStyleVerificationV1 {
        let prefix = "Blueprint verification: "
        let sources = try entry.guidance.filter { $0.hasPrefix(prefix) }.map {
            try JSONDecoder().decode(ProductionStyleCriterionV1.self, from: Data($0.dropFirst(prefix.count).utf8))
        }
        guard let criterion = sources.first(where: { $0.dimension == dimension }) else {
            throw invalid("Blueprint \(entry.id.rawValue) has no source verification for \(dimension.rawValue).")
        }
        return .init(scope: criterion.scope, evidenceKind: criterion.evidenceKind, criterion: criterion.sourceClause)
    }

    private static func result(library: CreativeKnowledgeLibraryV1, candidates: [ProductionStyleCandidateV1],
                               clarification: [String], disclosure: [String]) -> ProductionStyleRecommendationV1 {
        .init(schema: ProductionStyleRecommendationV1.schemaVersion, libraryVersion: library.version.rawValue,
              candidates: Array(candidates.prefix(2)), clarification: clarification, disclosure: disclosure)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unique(_ entries: [CreativeKnowledgeEntryV1]) -> [CreativeKnowledgeEntryV1] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id.rawValue).inserted }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func invalid(_ reason: String) -> ProductionKnowledgeErrorV1 {
        .invalidValue(path: "production-style-advisor", reason: reason)
    }
}
