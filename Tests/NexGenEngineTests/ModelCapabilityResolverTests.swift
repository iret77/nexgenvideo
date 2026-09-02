import Foundation
import Testing
@testable import NexGenEngine

@Suite("Model capability resolver")
struct ModelCapabilityResolverTests {
    @Test("release lineage selects 2.10 after 2.9 and resolves each field independently")
    func releaseLineageAndPartialInheritance() throws {
        let resolver = try ModelCapabilityResolver(knowledgeBase: makeKnowledgeBase())

        let exact = try resolver.resolve(
            CapabilityLookupV1(
                familyID: "seedance",
                variantID: "reference-to-video",
                versionID: "2.10",
                modality: .video
            )
        )
        let exactReferences = try #require(
            exact.fields.integers[CapabilityFieldIDV1.referenceImages]
        )
        let inheritedCharacters = try #require(
            exact.fields.integers[CapabilityFieldIDV1.visibleCharacters]
        )
        #expect(exactReferences.value == 50)
        #expect(exactReferences.origin.kind == .exact)
        #expect(inheritedCharacters.value == 2)
        #expect(inheritedCharacters.origin.kind == .inherited)
        #expect(inheritedCharacters.origin.versionID == "2.9")

        let future = try resolver.resolve(
            CapabilityLookupV1(
                familyID: "seedance",
                variantID: "reference-to-video",
                versionID: "3.0",
                modality: .video
            )
        )
        let futureReferences = try #require(
            future.fields.integers[CapabilityFieldIDV1.referenceImages]
        )
        #expect(future.requestedIdentity?.versionID == "3.0")
        #expect(future.resolvedIdentity?.versionID == "2.10")
        #expect(futureReferences.value == 50)
        #expect(futureReferences.origin.kind == .inherited)
        #expect(future.researchNeeded)
    }

    @Test("curated provider aliases share intrinsic truth but keep endpoint overlays separate")
    func aliasesAndEndpointOverlays() throws {
        let resolver = try ModelCapabilityResolver(knowledgeBase: makeKnowledgeBase())
        let falLookup = CapabilityLookupV1(
            modality: .video,
            catalogModelID: "fal/seedance-reference"
        )
        let higgsfieldLookup = CapabilityLookupV1(
            modality: .video,
            catalogModelID: "higgsfield/seedance-reference"
        )
        let fal = try resolver.resolve(falLookup)
        let higgsfield = try resolver.resolve(higgsfieldLookup)
        #expect(fal.resolvedIdentity == higgsfield.resolvedIdentity)
        #expect(fal.fields == higgsfield.fields)

        let falOffering = offering(
            provider: "fal",
            offer: "fal/limited",
            model: "fal/seedance-reference"
        )
        let higgsfieldOffering = offering(
            provider: "higgsfield",
            offer: "higgsfield/unbounded-schema",
            model: "higgsfield/seedance-reference"
        )
        let missingArgumentOffering = offering(
            provider: "provider",
            offer: "provider/no-reference-argument",
            model: "fal/seedance-reference"
        )
        let bounded = try resolver.resolveOffering(
            falOffering,
            lookup: falLookup,
            overlay:
            EndpointCapabilityOverlayV1(
                offering: falOffering,
                schemaEvidence: [evidence(kind: .providerSchema)],
                arrayConstraints: [
                    CapabilityFieldIDV1.referenceImages: EndpointArrayConstraintV1(
                        isPresent: true,
                        maxItems: 9
                    ),
                ]
            )
        )
        let noDeclaredMaximum = try resolver.resolveOffering(
            higgsfieldOffering,
            lookup: higgsfieldLookup,
            overlay:
            EndpointCapabilityOverlayV1(
                offering: higgsfieldOffering,
                schemaEvidence: [evidence(kind: .providerSchema)],
                arrayConstraints: [
                    CapabilityFieldIDV1.referenceImages: EndpointArrayConstraintV1(
                        isPresent: true
                    ),
                ]
            )
        )
        let argumentMissing = try resolver.resolveOffering(
            missingArgumentOffering,
            lookup: falLookup,
            overlay:
            EndpointCapabilityOverlayV1(
                offering: missingArgumentOffering,
                schemaEvidence: [evidence(kind: .providerSchema)],
                arrayConstraints: [
                    CapabilityFieldIDV1.referenceImages: EndpointArrayConstraintV1(
                        isPresent: false
                    ),
                ]
            )
        )

        #expect(bounded.effective.fields.integers[CapabilityFieldIDV1.referenceImages]?.value == 9)
        #expect(noDeclaredMaximum.effective.fields.integers[CapabilityFieldIDV1.referenceImages]?.value == 50)
        #expect(argumentMissing.effective.fields.integers[CapabilityFieldIDV1.referenceImages]?.value == 0)
        #expect(fal.fields.integers[CapabilityFieldIDV1.referenceImages]?.value == 50)
        #expect(
            bounded.effective.fields.integers[CapabilityFieldIDV1.referenceImages]?.origin.endpointID
                == "fal/limited"
        )
        #expect(noDeclaredMaximum.offering == higgsfieldOffering)
    }

    @Test("unknown and ambiguous families use the modality defensive profile")
    func defensiveResolution() throws {
        let resolver = try ModelCapabilityResolver(knowledgeBase: makeKnowledgeBase())

        let unknown = try resolver.resolve(
            CapabilityLookupV1(
                familyID: "hupfntrupfn",
                variantID: "default",
                versionID: "1",
                modality: .video
            )
        )
        #expect(unknown.resolvedIdentity == nil)
        #expect(unknown.defensiveProfileID == "defensive.video.fixture-v1")
        #expect(unknown.researchNeeded)
        #expect(unknown.fields.integers[CapabilityFieldIDV1.referenceImages]?.value == 1)

        let ambiguous = try resolver.resolve(
            CapabilityLookupV1(modality: .video, catalogModelID: "ambiguous/model")
        )
        #expect(ambiguous.requestedIdentity == nil)
        #expect(ambiguous.defensiveProfileID == "defensive.video.fixture-v1")

        let offering = CapabilityOfferingIdentityV1(
            providerID: "higgsfield",
            offeringID: "generate_image/unknown",
            endpointID: "generate_image",
            catalogModelID: "unknown/image",
            modality: .image
        )
        let endpointResolved = try resolver.resolveOffering(
            offering,
            lookup: CapabilityLookupV1(
                modality: .image,
                catalogModelID: "unknown/image"
            ),
            overlay: EndpointCapabilityOverlayV1(
                offering: offering,
                schemaEvidence: [evidence(kind: .providerSchema)],
                arrayConstraints: [
                    CapabilityFieldIDV1.imageReferences: EndpointArrayConstraintV1(
                        isPresent: true,
                        maxItems: 14
                    ),
                ]
            )
        )
        #expect(
            endpointResolved.effective.fields.integers[
                CapabilityFieldIDV1.imageReferences
            ]?.value == 14
        )
    }

    @Test("the resolver introduces no global high or low capability clamp")
    func noGlobalClamp() throws {
        let resolver = try ModelCapabilityResolver(knowledgeBase: makeKnowledgeBase())
        let high = try resolver.resolve(
            CapabilityLookupV1(
                familyID: "synthetic-high",
                variantID: "default",
                versionID: "1",
                modality: .video
            )
        )
        let low = try resolver.resolve(
            CapabilityLookupV1(
                familyID: "synthetic-low",
                variantID: "default",
                versionID: "1",
                modality: .video
            )
        )
        #expect(high.fields.integers[CapabilityFieldIDV1.visibleCharacters]?.value == 500)
        #expect(low.fields.integers[CapabilityFieldIDV1.visibleCharacters]?.value == 1)
    }

    @Test("endpoint merge policy raises minimums, lowers maximums, and rejects intrinsic-only fields")
    func endpointMergePolicies() throws {
        let resolver = try ModelCapabilityResolver(knowledgeBase: makeKnowledgeBase())
        let lookup = CapabilityLookupV1(
            modality: .video,
            catalogModelID: "fal/seedance-reference"
        )
        let route = offering(
            provider: "fal",
            offer: "fal/duration-limited",
            model: "fal/seedance-reference"
        )
        let resolved = try resolver.resolveOffering(
            route,
            lookup: lookup,
            overlay: EndpointCapabilityOverlayV1(
                offering: route,
                schemaEvidence: [evidence(kind: .providerSchema)],
                restrictions: EndpointCapabilityRestrictionsV1(
                    decimals: [
                        CapabilityFieldIDV1.durationMinimum: EndpointDecimalRestrictionV1(
                            value: 4,
                            operation: .minimum,
                            evidence: [evidence(kind: .providerSchema)]
                        ),
                        CapabilityFieldIDV1.durationMaximum: EndpointDecimalRestrictionV1(
                            value: 12,
                            operation: .maximum,
                            evidence: [evidence(kind: .providerSchema)]
                        ),
                    ]
                )
            )
        )
        #expect(
            resolved.effective.fields.decimals[CapabilityFieldIDV1.durationMinimum]?.value == 4
        )
        #expect(
            resolved.effective.fields.decimals[CapabilityFieldIDV1.durationMaximum]?.value == 12
        )

        #expect(throws: ModelCapabilityKnowledgeError.invalidEndpointMergePolicy(
            CapabilityFieldIDV1.knownExclusivities
        )) {
            _ = try resolver.resolveOffering(
                route,
                lookup: lookup,
                overlay: EndpointCapabilityOverlayV1(
                    offering: route,
                    schemaEvidence: [evidence(kind: .providerSchema)],
                    restrictions: EndpointCapabilityRestrictionsV1(
                        strings: [
                            CapabilityFieldIDV1.knownExclusivities:
                                EndpointStringListRestrictionV1(
                                    values: [],
                                    evidence: [evidence(kind: .providerSchema)]
                                ),
                        ]
                    )
                )
            )
        }
    }

    @Test("endpoint-only input policies resolve without a global defensive fallback")
    func endpointOnlyInputPolicies() throws {
        let resolver = try ModelCapabilityResolver(knowledgeBase: makeKnowledgeBase())
        let lookup = CapabilityLookupV1(
            modality: .video,
            catalogModelID: "fal/seedance-reference"
        )
        let offering = offering(
            provider: "fal",
            offer: "fal/exact-input-policy",
            model: "fal/seedance-reference"
        )
        let endpointEvidence = evidence(kind: .providerSchema)
        let resolved = try resolver.resolveOffering(
            offering,
            lookup: lookup,
            overlay: EndpointCapabilityOverlayV1(
                offering: offering,
                schemaEvidence: [endpointEvidence],
                restrictions: EndpointCapabilityRestrictionsV1(booleans: [
                    CapabilityFieldIDV1.sourceVideoRequired:
                        EndpointBooleanRestrictionV1(
                            value: true,
                            evidence: [endpointEvidence]
                        ),
                    CapabilityFieldIDV1.framesCountTowardImageReferenceLimit:
                        EndpointBooleanRestrictionV1(
                            value: false,
                            evidence: [endpointEvidence]
                        ),
                    CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit:
                        EndpointBooleanRestrictionV1(
                            value: true,
                            evidence: [endpointEvidence]
                        ),
                ])
            )
        )

        let intrinsicFields = resolved.intrinsic.fields.booleans
        #expect(intrinsicFields[CapabilityFieldIDV1.sourceVideoRequired]?.value == false)
        #expect(
            intrinsicFields[CapabilityFieldIDV1.framesCountTowardImageReferenceLimit]?.value
                == true
        )
        #expect(
            intrinsicFields[CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit]?.value
                == false
        )
        let fields = resolved.effective.fields.booleans
        #expect(fields[CapabilityFieldIDV1.sourceVideoRequired]?.value == true)
        #expect(
            fields[CapabilityFieldIDV1.framesCountTowardImageReferenceLimit]?.value == false
        )
        #expect(
            fields[CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit]?.value == true
        )
        #expect(
            fields[CapabilityFieldIDV1.sourceVideoRequired]?.origin.kind == .endpointOverlay
        )
        #expect(
            fields[CapabilityFieldIDV1.sourceVideoRequired]?.origin.endpointID
                == offering.endpointID
        )
        #expect(
            fields[CapabilityFieldIDV1.framesCountTowardImageReferenceLimit]?.origin.kind
                == .endpointOverlay
        )
        #expect(
            fields[CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit]?.origin.endpointID
                == offering.endpointID
        )
    }

    @Test("defensive profiles are complete, registered, and correctly typed")
    func defensiveFieldRegistryIsClosed() {
        var incomplete = makeKnowledgeBase()
        let video = DefensiveCapabilityProfileV1(
            id: "incomplete",
            modality: .video,
            fields: CapabilityFieldsV1(
                integers: [CapabilityFieldIDV1.referenceImages: defensiveField(1)]
            )
        )
        incomplete = ModelCapabilityKnowledgeBaseV1(
            profiles: incomplete.profiles,
            aliases: incomplete.aliases,
            defensiveProfiles: [video] + incomplete.defensiveProfiles.filter {
                $0.modality != .video
            }
        )
        #expect(throws: ModelCapabilityKnowledgeError.self) {
            _ = try ModelCapabilityResolver(knowledgeBase: incomplete)
        }

        let unknownField = ModelCapabilityKnowledgeBaseV1(
            profiles: [
                ModelCapabilityProfileV1(
                    identity: identity(family: "closed", variant: "default", version: "1"),
                    fields: CapabilityFieldsV1(integers: ["invented.limit": field(1)])
                ),
            ],
            aliases: [],
            defensiveProfiles: makeKnowledgeBase().defensiveProfiles
        )
        #expect(throws: ModelCapabilityKnowledgeError.unknownField("invented.limit")) {
            _ = try ModelCapabilityResolver(knowledgeBase: unknownField)
        }
    }

    @Test("capability identity IDs encode as canonical strings")
    func identityEncoding() throws {
        let identity = ModelCapabilityIdentityV1(
            familyID: "family",
            variantID: "variant",
            versionID: "2.10",
            modality: .image
        )
        let data = try JSONEncoder().encode(identity)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["family_id"] as? String == "family")
        #expect(object["variant_id"] as? String == "variant")
        #expect(object["version_id"] as? String == "2.10")
    }

    @Test("catalog audit assigns every visible model exactly one resolution class")
    func catalogAudit() throws {
        let resolver = try ModelCapabilityResolver(knowledgeBase: makeKnowledgeBase())
        let audit = try resolver.audit([
            CatalogCapabilityAuditInputV1(
                catalogModelID: "fal/seedance-reference",
                modality: .video
            ),
            CatalogCapabilityAuditInputV1(
                catalogModelID: "future/seedance",
                modality: .video,
                familyID: "seedance",
                variantID: "reference-to-video",
                versionID: "3.0"
            ),
            CatalogCapabilityAuditInputV1(
                catalogModelID: "unknown/model",
                modality: .image
            ),
        ])
        #expect(audit.records.map(\.resolution) == [.exact, .inherited, .defensive])
        #expect(audit.records.count == 3)
        #expect(
            audit.records[0].fieldOrigins[CapabilityFieldIDV1.visibleCharacters]?.kind
                == .inherited
        )

        #expect(throws: CatalogCapabilityAuditError.duplicateCatalogModelID("same")) {
            _ = try resolver.audit([
                CatalogCapabilityAuditInputV1(catalogModelID: "same", modality: .video),
                CatalogCapabilityAuditInputV1(catalogModelID: "same", modality: .video),
            ])
        }
    }

    @Test("knowledge-base codec is canonical and rejects an incompatible schema")
    func knowledgeBaseCodec() throws {
        let knowledgeBase = makeKnowledgeBase()
        let first = try ModelCapabilityKnowledgeBaseCodec.encode(knowledgeBase)
        let second = try ModelCapabilityKnowledgeBaseCodec.encode(knowledgeBase)
        #expect(first == second)
        #expect(try ModelCapabilityKnowledgeBaseCodec.decode(first) == knowledgeBase)

        let incompatible = Data(
            String(decoding: first, as: UTF8.self)
                .replacingOccurrences(
                    of: modelCapabilityKnowledgeBaseV1Schema,
                    with: "model-capability-kb/v99"
                )
                .utf8
        )
        #expect(
            throws: ModelCapabilityKnowledgeError.unsupportedSchema(
                "model-capability-kb/v99"
            )
        ) {
            _ = try ModelCapabilityKnowledgeBaseCodec.decode(incompatible)
        }
    }

    private func makeKnowledgeBase() -> ModelCapabilityKnowledgeBaseV1 {
        let seedance29 = identity(
            family: "seedance",
            variant: "reference-to-video",
            version: "2.9"
        )
        let seedance210 = identity(
            family: "seedance",
            variant: "reference-to-video",
            version: "2.10"
        )
        let alternate = identity(
            family: "other-family",
            variant: "default",
            version: "1"
        )
        return ModelCapabilityKnowledgeBaseV1(
            profiles: [
                ModelCapabilityProfileV1(
                    identity: seedance210,
                    predecessorVersionID: "2.9",
                    fields: CapabilityFieldsV1(
                        integers: [
                            CapabilityFieldIDV1.referenceImages: field(50),
                        ],
                        booleans: [
                            CapabilityFieldIDV1.sourceVideoRequired:
                                booleanField(false),
                            CapabilityFieldIDV1.framesCountTowardImageReferenceLimit:
                                booleanField(true),
                            CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit:
                                booleanField(false),
                        ]
                    )
                ),
                ModelCapabilityProfileV1(
                    identity: seedance29,
                    fields: CapabilityFieldsV1(
                        integers: [
                            CapabilityFieldIDV1.referenceImages: field(9),
                            CapabilityFieldIDV1.visibleCharacters: field(2),
                        ],
                        decimals: [
                            CapabilityFieldIDV1.durationMinimum: decimalField(1),
                            CapabilityFieldIDV1.durationMaximum: decimalField(30),
                        ]
                    )
                ),
                ModelCapabilityProfileV1(
                    identity: alternate,
                    fields: CapabilityFieldsV1(
                        integers: [CapabilityFieldIDV1.referenceImages: field(3)]
                    )
                ),
                ModelCapabilityProfileV1(
                    identity: identity(
                        family: "synthetic-high",
                        variant: "default",
                        version: "1"
                    ),
                    fields: CapabilityFieldsV1(
                        integers: [CapabilityFieldIDV1.visibleCharacters: field(500)]
                    )
                ),
                ModelCapabilityProfileV1(
                    identity: identity(
                        family: "synthetic-low",
                        variant: "default",
                        version: "1"
                    ),
                    fields: CapabilityFieldsV1(
                        integers: [CapabilityFieldIDV1.visibleCharacters: field(1)]
                    )
                ),
            ],
            aliases: [
                ModelCapabilityAliasV1(
                    catalogModelID: "fal/seedance-reference",
                    identity: seedance210
                ),
                ModelCapabilityAliasV1(
                    catalogModelID: "higgsfield/seedance-reference",
                    identity: seedance210
                ),
                ModelCapabilityAliasV1(
                    catalogModelID: "ambiguous/model",
                    identity: seedance210
                ),
                ModelCapabilityAliasV1(
                    catalogModelID: "ambiguous/model",
                    identity: alternate
                ),
            ],
            defensiveProfiles: [
                DefensiveCapabilityProfileV1(
                    id: "defensive.video.fixture-v1",
                    modality: .video,
                    fields: defensiveFields(for: .video)
                ),
                DefensiveCapabilityProfileV1(
                    id: "defensive.image.fixture-v1",
                    modality: .image,
                    fields: defensiveFields(for: .image)
                ),
                DefensiveCapabilityProfileV1(
                    id: "defensive.audio.fixture-v1",
                    modality: .audio,
                    fields: defensiveFields(for: .audio)
                ),
                DefensiveCapabilityProfileV1(
                    id: "defensive.music.fixture-v1",
                    modality: .music,
                    fields: defensiveFields(for: .music)
                ),
            ]
        )
    }

    private func identity(
        family: ModelFamilyID,
        variant: ModelVariantID,
        version: ModelVersionID
    ) -> ModelCapabilityIdentityV1 {
        ModelCapabilityIdentityV1(
            familyID: family,
            variantID: variant,
            versionID: version,
            modality: .video
        )
    }

    private func field(_ value: Int) -> EvidencedCapabilityFieldV1<Int> {
        EvidencedCapabilityFieldV1(
            value: value,
            semantics: .hardAPILimit,
            evidence: [evidence(kind: .providerSchema)]
        )
    }

    private func decimalField(_ value: Double) -> EvidencedCapabilityFieldV1<Double> {
        EvidencedCapabilityFieldV1(
            value: value,
            semantics: .hardAPILimit,
            evidence: [evidence(kind: .providerSchema)]
        )
    }

    private func booleanField(_ value: Bool) -> EvidencedCapabilityFieldV1<Bool> {
        EvidencedCapabilityFieldV1(
            value: value,
            semantics: .supportedValue,
            evidence: [evidence(kind: .providerSchema)]
        )
    }

    private func defensiveField<Value>(_ value: Value) -> EvidencedCapabilityFieldV1<Value>
    where Value: Codable & Sendable & Equatable {
        EvidencedCapabilityFieldV1(
            value: value,
            semantics: .defensiveDefault,
            evidence: [evidence(kind: .defensive)]
        )
    }

    private func defensiveFields(for modality: CapabilityModalityV1) -> CapabilityFieldsV1 {
        var fields = CapabilityFieldsV1()
        for definition in CapabilityFieldRegistryV1.requiredDefensiveFields(for: modality) {
            switch definition.valueType {
            case .integer:
                let value = [
                    CapabilityFieldIDV1.visibleCharacters,
                    CapabilityFieldIDV1.referenceImages,
                    CapabilityFieldIDV1.imageVisibleCharacters,
                    CapabilityFieldIDV1.imageReferences,
                    CapabilityFieldIDV1.imageOutputsPerRequest,
                ].contains(definition.id) ? 1 : 0
                fields.integers[definition.id] = defensiveField(value)
            case .decimal:
                let value = definition.id.hasSuffix("maximum_seconds") ? 30.0 : 0.0
                fields.decimals[definition.id] = defensiveField(value)
            case .boolean:
                fields.booleans[definition.id] = defensiveField(false)
            case .stringList:
                fields.strings[definition.id] = defensiveField([] as [String])
            case .integerList:
                fields.integerLists[definition.id] = defensiveField([] as [Int])
            }
        }
        return fields
    }

    private func offering(
        provider: String,
        offer: String,
        model: String
    ) -> CapabilityOfferingIdentityV1 {
        CapabilityOfferingIdentityV1(
            providerID: provider,
            offeringID: offer,
            endpointID: offer,
            catalogModelID: model,
            modality: .video
        )
    }

    private func evidence(kind: CapabilityEvidenceKindV1) -> CapabilityEvidenceV1 {
        CapabilityEvidenceV1(
            sourceTitle: "Offline fixture",
            observedAt: "2026-08-31",
            kind: kind,
            confidence: kind == .defensive ? 1 : 0.9
        )
    }
}
