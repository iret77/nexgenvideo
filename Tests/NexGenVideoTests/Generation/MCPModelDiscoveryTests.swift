import Testing
import Foundation
import MCP

@testable import NexGenVideo

/// The pure Tool→CatalogEntry mapping + the gate invariant for runtime MCP model discovery (#163).
/// Fixtures are trimmed from the REAL Higgsfield MCP payloads (`models_explore(action:list)` and its
/// `tools/list`), so the mapping is tested against the shape it will actually meet. The live browser
/// OAuth + discovery round-trip is verified on-device (no account in CI).
@Suite("MCP model discovery — tool → catalog mapping + gate")
struct MCPModelDiscoveryTests {

    private func tool(_ name: String, _ description: String? = nil) -> MCPProviderClient.DiscoveredTool {
        MCPProviderClient.DiscoveredTool(name: name, description: description, inputSchema: .object([:]))
    }

    // Real Higgsfield generate + catalog + editing tools, as `tools/list` returns them.
    private var higgsfieldTools: [MCPProviderClient.DiscoveredTool] {
        [tool("generate_video", "Generate a video."),
         tool("generate_image", "Generate an image."),
         tool("generate_audio", "Generate speech/voice audio (text-to-speech)."),
         tool("models_explore", "Find generation models."),
         tool("upscale_image", "Enhance or increase resolution."),
         tool("reframe", "Change a video's aspect ratio."),
         tool("remove_background", "Cutout / transparent background.")]
    }

    // Two real items from models_explore(action:list, type:video), plus the paging envelope.
    private let videoListing = #"""
    {"items":[
      {"id":"cinematic_studio_3_0","name":"Cinema Studio Video 3.0","provider_name":"Higgsfield",
       "description":"Most advanced cinema-grade model","output_type":"video",
       "parameters":[{"name":"resolution","type":"string","default":"720p","options":["480p","720p","1080p","4k"]},
                     {"name":"generate_audio","type":"bool","default":false}],
       "medias":[{"name":"medias","type":"image","roles":["image","start_image","end_image"]}],
       "aspect_ratios":["auto","21:9","16:9","9:16"],"tags":["cinematic","premium"],"duration_range":{"min":4,"max":15}},
      {"id":"cinematic_studio_video","name":"Cinema Studio Video","provider_name":"Higgsfield",
       "description":"Solid cinematic","output_type":"video",
       "medias":[{"name":"medias","type":"image","roles":["image","start_image","end_image"]}],
       "aspect_ratios":["1:1","16:9","9:16"],"tags":["cinematic"],"durations":[5,10]}
    ],"has_more":true,"next_page_token":"4"}
    """#

    // MARK: - tool classification

    @Test func generateToolsMapToModalitiesEditorsExcluded() {
        let byModality = MCPModelDiscovery.generateToolsByModality(higgsfieldTools)
        #expect(byModality[.video] == "generate_video")
        #expect(byModality[.image] == "generate_image")
        #expect(byModality[.audio] == "generate_audio")
        // models_explore, upscale_image, reframe, remove_background are not generators → no bucket.
        #expect(byModality[.upscale] == nil)
        #expect(byModality.count == 3)
    }

    @Test func audioBeatsBroaderVideoImageKeywords() {
        // A "sound" tool must bucket as audio, not get grabbed by a stray token.
        #expect(MCPModelDiscovery.modality(name: "generate_sound_effect", description: nil) == .audio)
        #expect(MCPModelDiscovery.modality(name: "upscale_video", description: "enhance") == .upscale)
        #expect(MCPModelDiscovery.isGenerative(name: "upscale_image", description: "Enhance resolution") == false)
        #expect(MCPModelDiscovery.isGenerative(name: "generate_video", description: "Generate a video.") == true)
    }

    // MARK: - listing parse

    @Test func parseListingReadsItemsAndCursor() {
        let parsed = MCPModelDiscovery.parseListingResult(videoListing)
        #expect(parsed.items.count == 2)
        #expect(parsed.items.first?.id == "cinematic_studio_3_0")
        #expect(parsed.items.first?.outputType == "video")
        #expect(parsed.next == "4")   // has_more:true → cursor surfaced
        #expect(parsed.pagination.hasMore == true)
        #expect(parsed.pagination.hasMoreWasPresent)
        #expect(parsed.pagination.cursor == "4")
        #expect(parsed.pagination.cursorWasPresent)
        #expect(parsed.isCatalogPayload)
        #expect(parsed.isComplete)
    }

    @Test func terminalPageWithCursorIsStructurallyIncomplete() {
        let lastPage = #"{"items":[{"id":"x","output_type":"video"}],"has_more":false,"next_page_token":"9"}"#
        let parsed = MCPModelDiscovery.parseListingResult(lastPage)
        let nested = MCPModelDiscovery.parseListingResult(
            #"{"has_more":false,"next_page_token":"outer","data":{"models":[{"id":"y","output_type":"image"}]}}"#
        )

        #expect(parsed.items.map(\.id) == ["x"])
        #expect(parsed.next == nil)
        #expect(parsed.pagination.hasMore == false)
        #expect(parsed.pagination.cursor == "9")
        #expect(parsed.isCatalogPayload)
        #expect(!parsed.isComplete)
        #expect(nested.items.map(\.id) == ["y"])
        #expect(nested.next == nil)
        #expect(!nested.isComplete)
    }

    @Test func parseListingToleratesGarbageAndBareArray() {
        let prose = MCPModelDiscovery.parseListingResult("Model catalog follows in the next content block.")
        let quotedProse = MCPModelDiscovery.parseListingResult("The \"models\" block follows next.")
        #expect(prose.items.isEmpty)
        #expect(!prose.isCatalogPayload)
        #expect(prose.isComplete)
        #expect(!quotedProse.isCatalogPayload)
        let bare = #"[{"id":"solo","output_type":"image"}]"#
        let parsed = MCPModelDiscovery.parseListingResult(bare)
        #expect(parsed.items.map(\.id) == ["solo"])
        #expect(parsed.next == nil)
        #expect(parsed.isCatalogPayload)
        #expect(parsed.isComplete)
    }

    @Test func malformedCatalogPayloadReportsIncompleteWithoutHidingDecodedModels() {
        let malformedJSON = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"broken","output_type":"image"}]"#,
            defaultOutputType: "image"
        )
        let malformedJSON5 = MCPModelDiscovery.parseListingResult(
            #"{items: [{id: "broken", output_type: "image"}]}"#,
            defaultOutputType: "image"
        )
        let prefixedMalformedJSON = MCPModelDiscovery.parseListingResult(
            #"Catalog: {"items":[{"id":"broken","output_type":"image"}]"#,
            defaultOutputType: "image"
        )
        let prefixedMalformedJSON5 = MCPModelDiscovery.parseListingResult(
            #"Catalog: {items: [{id: "broken", output_type: "image"}]}"#,
            defaultOutputType: "image"
        )
        let partiallyDecodable = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"kept","output_type":"image"},{"id":7,"output_type":"image"}]}"#,
            defaultOutputType: "image"
        )
        let malformedEnvelope = MCPModelDiscovery.parseListingResult(
            #"{"items":"not-an-array"}"#,
            defaultOutputType: "image"
        )

        #expect(malformedJSON.isCatalogPayload)
        #expect(!malformedJSON.isComplete)
        #expect(malformedJSON5.isCatalogPayload)
        #expect(!malformedJSON5.isComplete)
        #expect(prefixedMalformedJSON.isCatalogPayload)
        #expect(!prefixedMalformedJSON.isComplete)
        #expect(prefixedMalformedJSON5.isCatalogPayload)
        #expect(!prefixedMalformedJSON5.isComplete)
        #expect(partiallyDecodable.items.map(\.id) == ["kept"])
        #expect(!partiallyDecodable.isComplete)
        #expect(malformedEnvelope.isCatalogPayload)
        #expect(!malformedEnvelope.isComplete)
    }

    @Test func malformedNextAndCursorAliasesRemainIncompleteCatalogPayloads() {
        for payload in [
            #"{"next":"must-not-follow""#,
            #"{cursor: "must-not-follow""#,
        ] {
            let parsed = MCPModelDiscovery.parseListingResult(payload)

            #expect(parsed.items.isEmpty)
            #expect(parsed.next == nil)
            #expect(parsed.isCatalogPayload)
            #expect(!parsed.structuralAndDecodeIsComplete)
            #expect(!parsed.isComplete)
        }
    }

    @Test func everyMalformedPaginationAliasAndKeyFormIsDetected() {
        let aliases = [
            "next_page_token", "nextPageToken", "next", "cursor", "has_more", "hasMore",
        ]
        for alias in aliases {
            for payload in [
                "{\"\(alias)\":\"value\"",
                "{'\(alias)':'value'",
                "{\(alias):'value'",
            ] {
                let parsed = MCPModelDiscovery.parseListingResult(payload)

                #expect(parsed.isCatalogPayload)
                #expect(!parsed.structuralAndDecodeIsComplete)
                #expect(!parsed.isComplete)
                #expect(parsed.next == nil)
            }
        }

        for payload in [
            #"{"cursor_extra":"value""#,
            #"{"note":"{cursor: value""#,
        ] {
            let parsed = MCPModelDiscovery.parseListingResult(payload)

            #expect(!parsed.isCatalogPayload)
            #expect(parsed.structuralAndDecodeIsComplete)
        }
    }

    @Test func everyMalformedCatalogAliasAndKeyFormIsDetected() {
        let aliases = [
            "items", "models", "job_sets", "jobSets", "model", "job_set", "jobSet",
            "job_set_type", "jobSetType", "model_id", "modelId", "output_type",
            "outputType", "modality",
        ]
        for alias in aliases {
            for payload in [
                "{\"\(alias)\":\"value\"",
                "{'\(alias)':'value'",
                "{\(alias):'value'",
            ] {
                let parsed = MCPModelDiscovery.parseListingResult(payload)

                #expect(parsed.isCatalogPayload)
                #expect(!parsed.structuralAndDecodeIsComplete)
                #expect(!parsed.isComplete)
            }
        }

        for payload in [
            #"{"items_extra":"value""#,
            #"{"note":"{model: value""#,
        ] {
            #expect(!MCPModelDiscovery.parseListingResult(payload).isCatalogPayload)
        }
    }

    @Test func malformedIdentityAndOperationalFieldsUseObjectKeyTokens() {
        for payload in [
            #"{"id":"candidate""#,
            #"{'id':'candidate'"#,
            #"{id:'candidate'"#,
        ] {
            let parsed = MCPModelDiscovery.parseListingResult(
                payload,
                defaultOutputType: "image"
            )

            #expect(parsed.isCatalogPayload)
            #expect(!parsed.isComplete)
        }

        for alias in ["status", "action"] {
            for payload in [
                "{\"id\":\"candidate\",\"\(alias)\":\"queued\"",
                "{'id':'candidate','\(alias)':'queued'",
                "{id:'candidate',\(alias):'queued'",
            ] {
                #expect(!MCPModelDiscovery.parseListingResult(
                    payload,
                    defaultOutputType: "image"
                ).isCatalogPayload)
            }

            for payload in [
                "{\"id\":\"candidate\",\"note\":\"\(alias)\"",
                "{'id':'candidate','note':'\(alias)'",
                "{id:'candidate',note:'\(alias)'",
            ] {
                #expect(MCPModelDiscovery.parseListingResult(
                    payload,
                    defaultOutputType: "image"
                ).isCatalogPayload)
            }
        }

        for payload in [
            #"{"note":"id""#,
            #"{'note':'id'"#,
            #"{note:'id'"#,
        ] {
            #expect(!MCPModelDiscovery.parseListingResult(
                payload,
                defaultOutputType: "image"
            ).isCatalogPayload)
        }
    }

    @Test func bareArraysRequireAValidModelObject() {
        for payload in ["[]", #"["metadata",7,true]"#, #"[{"id":"request","status":"done"}]"#] {
            let parsed = MCPModelDiscovery.parseListingResult(payload)

            #expect(parsed.items.isEmpty)
            #expect(!parsed.isCatalogPayload)
            #expect(parsed.isComplete)
        }

        let mixed = MCPModelDiscovery.parseListingResult(
            #"["metadata",{"id":"model","output_type":"image"},7]"#
        )

        #expect(mixed.items.map(\.id) == ["model"])
        #expect(mixed.isCatalogPayload)
        #expect(!mixed.structuralAndDecodeIsComplete)
        #expect(!mixed.isComplete)
    }

    @Test func bareDetailArraysRequireADecodableCanonicalIdentity() {
        for payload in [
            #"[{"note":"metadata"}]"#,
            #"[{"id":""}]"#,
            #"[{"id":"   "}]"#,
            #"[{"id":7}]"#,
            #"[{"id":"","job_set_type":"hidden-by-empty-id"}]"#,
            #"[{"id":7,"jobSetType":"hidden-by-invalid-id"}]"#,
            #"[{"id":"model","parameters":"invalid"}]"#,
        ] {
            let parsed = MCPModelDiscovery.parseListingResult(
                payload,
                context: .detail
            )

            #expect(parsed.items.isEmpty)
            #expect(!parsed.isCatalogPayload)
            #expect(parsed.isComplete)
        }

        for (payload, expectedID) in [
            (#"[{"id":"by-id"}]"#, "by-id"),
            (#"[{"job_set_type":"by-job-set"}]"#, "by-job-set"),
            (#"[{"jobSetType":"by-job-set-camel"}]"#, "by-job-set-camel"),
            (#"[{"model_id":"by-model-id"}]"#, "by-model-id"),
            (#"[{"modelId":"by-model-id-camel"}]"#, "by-model-id-camel"),
        ] {
            let parsed = MCPModelDiscovery.parseListingResult(
                payload,
                context: .detail
            )

            #expect(parsed.items.map(\.id) == [expectedID])
            #expect(parsed.isCatalogPayload)
            #expect(parsed.isComplete)
        }

        let standalone = MCPModelDiscovery.parseListingResult(
            #"{"id":"detail-object","constraints":[]}"#,
            context: .detail
        )
        let mixed = MCPModelDiscovery.parseListingResult(
            #"[{"note":"metadata"},{"id":"detail-model","constraints":[]},{"id":7}]"#,
            context: .detail
        )

        #expect(standalone.items.map(\.id) == ["detail-object"])
        #expect(standalone.isComplete)
        #expect(mixed.items.map(\.id) == ["detail-model"])
        #expect(mixed.isCatalogPayload)
        #expect(!mixed.structuralAndDecodeIsComplete)
        #expect(!mixed.isComplete)
    }

    @Test func constraintsDecodeOnlyMissingNullStringOrStringArray() {
        let missing = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"missing","output_type":"image"}]}"#
        )
        let null = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"null","output_type":"image","constraints":null}]}"#
        )
        let string = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"string","output_type":"image","constraints":"At most 2 image references are allowed."}]}"#
        )
        let array = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"array","output_type":"image","constraints":["First","Second"]}]}"#
        )
        let emptyArray = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"empty-array","output_type":"image","constraints":[]}]}"#
        )

        #expect(missing.items.first?.constraints == nil)
        #expect(null.items.first?.constraints == nil)
        #expect(string.items.first?.constraints == ["At most 2 image references are allowed."])
        #expect(array.items.first?.constraints == ["First", "Second"])
        #expect(emptyArray.items.first?.constraints == [])
        #expect([missing, null, string, array, emptyArray].allSatisfy(\.isComplete))

        for invalidValue in ["7", "true", "{}", "[1,2]", #"["valid",7]"#] {
            let collection = MCPModelDiscovery.parseListingResult(
                "{\"items\":[{\"id\":\"invalid\",\"output_type\":\"image\",\"constraints\":\(invalidValue)}]}"
            )
            let detail = MCPModelDiscovery.parseListingResult(
                "{\"id\":\"invalid-detail\",\"constraints\":\(invalidValue)}",
                context: .detail
            )

            #expect(collection.items.isEmpty)
            #expect(collection.isCatalogPayload)
            #expect(!collection.structuralAndDecodeIsComplete)
            #expect(!collection.isComplete)
            #expect(detail.items.isEmpty)
            #expect(detail.isCatalogPayload)
            #expect(!detail.structuralAndDecodeIsComplete)
            #expect(!detail.isComplete)
        }
    }

    @Test func multipleCatalogFragmentsAreScannedWithoutDiscardingTrailingLoss() {
        let validFragments = MCPModelDiscovery.parseListingResult(
            #"Before {"items":[{"id":"first","output_type":"image"}]} {"items":[{"id":"second","output_type":"image"}]} after."#
        )
        let malformedTrailingFragment = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"kept","output_type":"image"}]} {"cursor":"must-not-follow""#
        )
        let proseSuffix = MCPModelDiscovery.parseListingResult(
            #"Before {"items":[{"id":"only","output_type":"image"}]} finished normally."#
        )
        let earlyGenericLoss = MCPModelDiscovery.parseListingResult(
            #"{"data":[} {"items":[{"id":"after-loss","output_type":"image"}]}"#
        )
        let trailingGenericLoss = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"before-loss","output_type":"image"}]} {"data":{"#
        )

        #expect(validFragments.items.map(\.id) == ["first", "second"])
        #expect(validFragments.isComplete)
        #expect(malformedTrailingFragment.items.map(\.id) == ["kept"])
        #expect(!malformedTrailingFragment.structuralAndDecodeIsComplete)
        #expect(malformedTrailingFragment.next == nil)
        #expect(!malformedTrailingFragment.isComplete)
        #expect(proseSuffix.items.map(\.id) == ["only"])
        #expect(proseSuffix.isComplete)
        #expect(earlyGenericLoss.items.map(\.id) == ["after-loss"])
        #expect(!earlyGenericLoss.structuralAndDecodeIsComplete)
        #expect(!earlyGenericLoss.isComplete)
        #expect(trailingGenericLoss.items.map(\.id) == ["before-loss"])
        #expect(!trailingGenericLoss.structuralAndDecodeIsComplete)
        #expect(!trailingGenericLoss.isComplete)
    }

    @Test func paginationContractReportsMissingContinuationAsIncomplete() {
        let missingCursor = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"first","output_type":"image"}],"has_more":true}"#
        )
        let nestedCursor = MCPModelDiscovery.parseListingResult(
            #"{"has_more":true,"data":{"models":[{"id":"second","output_type":"image"}],"next_page_token":"page-2"}}"#
        )
        let emptyLastPage = MCPModelDiscovery.parseListingResult(
            #"{"items":[],"has_more":false}"#
        )
        let cursorOnly = MCPModelDiscovery.parseListingResult(
            #"{"next_page_token":"page-3"}"#
        )
        let conflictingHasMore = MCPModelDiscovery.parseListingResult(
            #"{"items":[],"has_more":false,"hasMore":true}"#
        )

        #expect(missingCursor.next == nil)
        #expect(missingCursor.structuralAndDecodeIsComplete)
        #expect(!missingCursor.isComplete)
        #expect(nestedCursor.next == "page-2")
        #expect(nestedCursor.isComplete)
        #expect(emptyLastPage.isCatalogPayload)
        #expect(emptyLastPage.isComplete)
        #expect(cursorOnly.pagination.hasMore == nil)
        #expect(!cursorOnly.pagination.hasMoreWasPresent)
        #expect(cursorOnly.pagination.cursorWasPresent)
        #expect(cursorOnly.next == "page-3")
        #expect(cursorOnly.isComplete)
        #expect(conflictingHasMore.pagination.hasMore == nil)
        #expect(conflictingHasMore.pagination.hasMoreWasPresent)
        #expect(conflictingHasMore.next == nil)
        #expect(!conflictingHasMore.structuralAndDecodeIsComplete)
        #expect(!conflictingHasMore.isComplete)
    }

    @Test func paginationRejectsNonBooleanHasMoreAndMalformedCursors() {
        for value in ["0", "1", #""true""#, "null"] {
            let parsed = MCPModelDiscovery.parseListingResult(
                "{\"items\":[],\"has_more\":\(value)}"
            )

            #expect(parsed.pagination.hasMore == nil)
            #expect(parsed.pagination.hasMoreWasPresent)
            #expect(!parsed.pagination.isStructurallyComplete)
            #expect(parsed.next == nil)
            #expect(!parsed.isComplete)
        }

        for value in ["7", #""""#] {
            let parsed = MCPModelDiscovery.parseListingResult(
                "{\"items\":[],\"has_more\":true,\"next_page_token\":\(value)}"
            )

            #expect(parsed.pagination.cursor == nil)
            #expect(parsed.pagination.cursorWasPresent)
            #expect(!parsed.pagination.isStructurallyComplete)
            #expect(parsed.next == nil)
            #expect(!parsed.isComplete)
        }

        let trueValue = MCPModelDiscovery.parseListingResult(
            #"{"items":[],"has_more":true,"next_page_token":"next"}"#
        )
        let falseValue = MCPModelDiscovery.parseListingResult(
            #"{"items":[],"has_more":false}"#
        )

        #expect(trueValue.pagination.hasMore == true)
        #expect(trueValue.next == "next")
        #expect(trueValue.isComplete)
        #expect(falseValue.pagination.hasMore == false)
        #expect(falseValue.next == nil)
        #expect(falseValue.isComplete)
    }

    @Test func directCollectionsKeepSiblingPaginationWithoutNestedModels() {
        let outerCursor = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"outer-a","output_type":"image"}],"next_page_token":"unexpected","data":{"models":[{"id":"nested-a","output_type":"image"}],"has_more":false}}"#
        )
        let outerTerminal = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"outer-b","output_type":"image"}],"has_more":false,"result":{"models":[{"id":"nested-b","output_type":"image"}],"next_page_token":"unexpected"}}"#
        )

        #expect(outerCursor.items.map(\.id) == ["outer-a"])
        #expect(outerCursor.next == nil)
        #expect(!outerCursor.isComplete)
        #expect(outerTerminal.items.map(\.id) == ["outer-b"])
        #expect(outerTerminal.next == nil)
        #expect(!outerTerminal.isComplete)
    }

    @Test func directSingleAndStandaloneModelsKeepSiblingPaginationOnly() {
        let single = MCPModelDiscovery.parseListingResult(
            #"{"model":{"id":"single","output_type":"image"},"next_page_token":"unexpected","data":{"model":{"id":"nested-single","output_type":"image"},"has_more":false}}"#
        )
        let standalone = MCPModelDiscovery.parseListingResult(
            #"{"id":"standalone","output_type":"image","has_more":false,"payload":{"model":{"id":"nested-standalone","output_type":"image"},"next_page_token":"unexpected"}}"#
        )

        #expect(single.items.map(\.id) == ["single"])
        #expect(single.next == nil)
        #expect(!single.isComplete)
        #expect(standalone.items.map(\.id) == ["standalone"])
        #expect(standalone.next == nil)
        #expect(!standalone.isComplete)
    }

    @Test func directModelsRetainMalformedNestedCatalogLoss() {
        let collection = MCPModelDiscovery.parseListingResult(
            #"{"items":[{"id":"collection","output_type":"image"}],"data":{"items":"invalid"}}"#
        )
        let single = MCPModelDiscovery.parseListingResult(
            #"{"model":{"id":"single","output_type":"image"},"result":{"model":"invalid"}}"#
        )
        let standalone = MCPModelDiscovery.parseListingResult(
            #"{"id":"standalone","output_type":"image","payload":{"items":"invalid"}}"#
        )

        #expect(collection.items.map(\.id) == ["collection"])
        #expect(!collection.structuralAndDecodeIsComplete)
        #expect(!collection.isComplete)
        #expect(single.items.map(\.id) == ["single"])
        #expect(!single.structuralAndDecodeIsComplete)
        #expect(!single.isComplete)
        #expect(standalone.items.map(\.id) == ["standalone"])
        #expect(!standalone.structuralAndDecodeIsComplete)
        #expect(!standalone.isComplete)
    }

    @Test func listingIgnoresAuxiliaryIdentifiersWithoutExplicitModality() {
        for payload in [
            #"{"id":"request-123","status":"completed"}"#,
            #"{"job_set_type":"generation-job","created_at":"now"}"#,
            #"{"model_id":"echoed-request-model","action":"list"}"#,
            #"{"model_id":"echoed-request-model","action":"list","type":"image"}"#,
            #"{"id":"request-123","status":"completed","output_type":"image"}"#,
            #"{"data":{"id":"nested-job","status":"queued"}}"#,
            #"{"data":[{"id":"nested-job","status":"queued"}]}"#,
        ] {
            #expect(MCPModelDiscovery.parseListing(
                payload,
                defaultOutputType: "image"
            ).items.isEmpty)
        }
    }

    @Test func standaloneListingRequiresExplicitModalityButDetailDoesNot() {
        let explicit = MCPModelDiscovery.parseListing(
            #"{"id":"real-image","output_type":"image"}"#
        )
        let detail = MCPModelDiscovery.parseListing(
            #"{"id":"detail-image","constraints":["At most 2 image references are allowed."]}"#,
            defaultOutputType: "image",
            context: .detail
        )

        #expect(explicit.items.map(\.id) == ["real-image"])
        #expect(detail.items.map(\.id) == ["detail-image"])
    }

    @Test func standaloneListingUsesModelSpecificModalityContracts() {
        let outputType = MCPModelDiscovery.parseListing(
            #"{"model_id":"real-image","output_type":"image"}"#
        )
        let modality = MCPModelDiscovery.parseListing(
            #"{"id":"real-video","modality":"video"}"#
        )
        let jobSetType = MCPModelDiscovery.parseListing(
            #"{"job_set_type":"real-job-set","type":"image"}"#
        )
        let genericType = MCPModelDiscovery.parseListing(
            #"{"model_id":"ambiguous-request","type":"image"}"#
        )

        #expect(outputType.items.map(\.id) == ["real-image"])
        #expect(modality.items.map(\.id) == ["real-video"])
        #expect(jobSetType.items.map(\.id) == ["real-job-set"])
        #expect(genericType.items.isEmpty)
    }

    @Test func mixedContentBlocksKeepDeclaredModelsWithoutPromotingMetadata() {
        let blocks = [
            #"{"items":[{"id":"first","output_type":"image"}]}"#,
            #"{"id":"request-123","status":"completed"}"#,
            #"{"job_set_type":"job-456","status":"queued"}"#,
            #"{"models":[{"id":"second","name":"Second"}]}"#,
        ]
        let ids = blocks.flatMap {
            MCPModelDiscovery.parseListing($0, defaultOutputType: "image").items
        }.map(\.id)

        #expect(ids == ["first", "second"])
    }

    @Test func currentHiggsfieldJobSetShapeIsDiscovered() {
        let listing = #"""
        {"data":{"models":[
          {"job_set_type":"nano_banana_2","display_name":"Nano Banana Pro","type":"image",
           "params":[{"name":"aspect_ratio","options":["1:1","16:9","9:16"]}]},
          {"job_set_type":"gpt_image_2","name":"GPT Image 2","modality":"image"}
        ]}}
        """#
        let parsed = MCPModelDiscovery.parseListing(listing)

        #expect(parsed.items.map(\.id) == ["nano_banana_2", "gpt_image_2"])
        #expect(parsed.items.map(\.outputType) == ["image", "image"])
        #expect(parsed.items.first?.name == "Nano Banana Pro")
    }

    @Test func requestedModalityFillsLeanCatalogItems() {
        let listing = #"{"items":[{"job_set_type":"nano_banana_2","name":"Nano Banana Pro"}]}"#
        let parsed = MCPModelDiscovery.parseListing(
            listing,
            defaultOutputType: "image"
        )

        #expect(parsed.items.first?.outputType == "image")
    }

    // MARK: - the mapping core

    @Test func modelsMapToGatedMcpCatalogEntries() {
        let (models, _) = MCPModelDiscovery.parseListing(videoListing)
        let byModality = MCPModelDiscovery.generateToolsByModality(higgsfieldTools)
        let entries = MCPModelDiscovery.catalogEntries(
            models: models, toolsByModality: byModality, provider: .higgsfield)

        #expect(entries.count == 2)
        let top = try! #require(entries.first { $0.id == "cinematic_studio_3_0" })
        #expect(top.displayName == "Cinema Studio Video 3.0")
        #expect(top.kind == .video)

        // The offer routes through the resolver over MCP, naming the generate TOOL + the MODEL id.
        let offer = try! #require(top.offers?.first)
        #expect(offer.provider == .higgsfield)
        #expect(offer.transport == .mcp)
        #expect(offer.providerRef == "generate_video")   // the tool NGV drives as client
        #expect(offer.modelParam == "cinematic_studio_3_0")  // the model arg NGV sends
        #expect(offer.mcpMediaRoles == ["end_image", "image", "start_image"])

        // Capabilities are lifted from the model's declared params/medias/ranges.
        guard case let .video(caps) = top.uiCapabilities else { Issue.record("expected video caps"); return }
        #expect(caps.resolutions == ["480p", "720p", "1080p", "4k"])
        #expect(caps.aspectRatios == ["21:9", "16:9", "9:16"])   // "auto" filtered out
        #expect(caps.durations.isEmpty)
        #expect(caps.duration.range == .init(min: 4, max: 15))
        #expect(caps.supportsFirstFrame)                         // start_image role present
        #expect(caps.supportsLastFrame)                          // end_image role present
        #expect(caps.maxReferenceImages == 0)                    // unresolved list cardinality fails closed
        #expect(top.card?.tags == ["cinematic", "premium"])

        // The second item uses an explicit durations list, not a range.
        let solid = try! #require(entries.first { $0.id == "cinematic_studio_video" })
        guard case let .video(caps2) = solid.uiCapabilities else { Issue.record("expected video caps"); return }
        #expect(caps2.durations == [5, 10])
    }

    @Test func seedance25DiscoveryPreservesRangeAndAuto() {
        let listing = #"""
        {"items":[{"id":"seedance_2_5","name":"Seedance 2.5","output_type":"video",
          "duration_range":{"min":4,"max":30},
          "parameters":[{"name":"duration","options":["auto",4,30]}],
          "aspect_ratios":["16:9","9:16"]}]}
        """#
        let (models, _) = MCPModelDiscovery.parseListing(listing)
        let entries = MCPModelDiscovery.catalogEntries(
            models: models, toolsByModality: [.video: "generate_video"], provider: .higgsfield)
        let entry = try! #require(entries.first)
        guard case let .video(caps) = entry.uiCapabilities else {
            Issue.record("expected video caps")
            return
        }
        #expect(caps.duration.discrete.isEmpty)
        #expect(caps.duration.range == .init(min: 4, max: 30))
        #expect(caps.duration.supportsAuto)
        #expect(entry.offers?.first?.modelParam == "seedance_2_5")
    }

    @Test func audioModelInfersCategoryFromTags() {
        let listing = #"""
        {"items":[
          {"id":"sonilo_music","name":"Sonilo Music","output_type":"audio","tags":["audio","music"]},
          {"id":"seed_audio","name":"Seed Audio 1.0","output_type":"audio","tags":["audio","tts"]},
          {"id":"mirelo_sfx","name":"Mirelo SFX","output_type":"audio","tags":["audio","sfx"],
           "medias":[{"name":"medias","type":"video","roles":["video"]}]}
        ]}
        """#
        let (models, _) = MCPModelDiscovery.parseListing(listing)
        let entries = MCPModelDiscovery.catalogEntries(
            models: models, toolsByModality: [.audio: "generate_audio"], provider: .higgsfield)
        let music = try! #require(entries.first { $0.id == "sonilo_music" })
        guard case let .audio(caps) = music.uiCapabilities else { Issue.record("expected audio caps"); return }
        #expect(caps.category == "music")
        #expect(caps.supportsLyrics)
        let tts = try! #require(entries.first { $0.id == "seed_audio" })
        guard case let .audio(caps2) = tts.uiCapabilities else { Issue.record("expected audio caps"); return }
        #expect(caps2.category == "tts")
        let videoSFX = try! #require(entries.first { $0.id == "mirelo_sfx" })
        guard case let .audio(caps3) = videoSFX.uiCapabilities else {
            Issue.record("expected audio caps")
            return
        }
        #expect(caps3.category == "sfx")
        #expect(caps3.inputs == ["text", "video"])
        #expect(caps3.minPromptLength == 0)
        #expect(videoSFX.offers?.first?.mcpMediaRoles == ["video"])
    }

    @Test func modelWithNoGenerateToolForItsModalityIsDropped() {
        let (models, _) = MCPModelDiscovery.parseListing(videoListing)
        // Only an audio generate tool is available → video models can't dispatch → dropped.
        let entries = MCPModelDiscovery.catalogEntries(
            models: models, toolsByModality: [.audio: "generate_audio"], provider: .higgsfield)
        #expect(entries.isEmpty)
    }

    @Test func incompatibleLiveGenerateSchemaDropsCatalogModels() {
        let (models, _) = MCPModelDiscovery.parseListing(videoListing)
        let schema: Value = .object([
            "properties": .object([
                "params": .object([
                    "properties": .object([
                        "model": .object(["type": .string("string")]),
                        "prompt": .object(["type": .string("string")]),
                        "workspace_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([
                        .string("model"), .string("prompt"), .string("workspace_id"),
                    ]),
                ]),
            ]),
            "required": .array([.string("params")]),
        ])

        let entries = MCPModelDiscovery.catalogEntries(
            models: models,
            toolsByModality: [.video: "generate_video"],
            toolSchemasByModality: [.video: schema],
            provider: .higgsfield
        )

        #expect(entries.isEmpty)
    }

    @Test func referenceCapabilitiesRequireProviderMediaUploadTools() {
        let listing = #"{"items":[{"id":"anchor","name":"Anchor","output_type":"image","medias":[{"name":"medias","type":"image","roles":["image_references"]}]}]}"#
        let (models, _) = MCPModelDiscovery.parseListing(listing)
        let entries = MCPModelDiscovery.catalogEntries(
            models: models,
            toolsByModality: [.image: "generate_image"],
            allowsLocalMedia: false,
            provider: .higgsfield
        )
        let entry = try! #require(entries.first)
        guard case .image(let caps) = entry.uiCapabilities else {
            Issue.record("expected image caps")
            return
        }

        #expect(!caps.supportsImageReference)
        #expect(entry.offers?.first?.mcpMediaRoles == [])
    }

    @Test func unresolvedReferenceLimitFailsClosed() {
        let listing = #"{"items":[{"id":"anchor","output_type":"image","medias":[{"name":"medias","type":"image","roles":["image_references"]}]}]}"#
        let (models, _) = MCPModelDiscovery.parseListing(listing)
        let entries = MCPModelDiscovery.catalogEntries(
            models: models,
            toolsByModality: [.image: "generate_image"],
            provider: .higgsfield
        )
        let entry = try! #require(entries.first)
        guard case .image(let caps) = entry.uiCapabilities else {
            Issue.record("expected image caps")
            return
        }

        #expect(caps.referenceImageLimit == .unknown)
        #expect(!caps.supportsImageReference)
    }

    @Test func toolOnlyFallbackRejectsUnsupportedRequiredSchema() {
        let schema: Value = .object([
            "properties": .object([
                "prompt": .object(["type": .string("string")]),
                "tenant_id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("prompt"), .string("tenant_id")]),
        ])
        let tools = [MCPProviderClient.DiscoveredTool(
            name: "generate_image",
            description: "Generate an image.",
            inputSchema: schema
        )]

        #expect(MCPModelDiscovery.catalogEntriesFromTools(tools, provider: .openart).isEmpty)
    }

    @Test func toolOnlyFallbackWhenNoCatalog() {
        // A provider with no model catalog: one entry per generate tool, dispatched by tool name,
        // no model argument.
        let entries = MCPModelDiscovery.catalogEntriesFromTools(higgsfieldTools, provider: .openart)
        #expect(entries.count == 3)   // video + image + audio, editors excluded
        let video = try! #require(entries.first { $0.id == "generate_video" })
        #expect(video.offers?.first?.transport == .mcp)
        #expect(video.offers?.first?.providerRef == "generate_video")
        #expect(video.offers?.first?.modelParam == nil)
    }

    // MARK: - gate invariant

    /// A discovered model routes through the SAME prompt-engine gate as every content model: its offer
    /// is `.generation` over `.mcp`, so `GenerationController` compiles+tokens before dispatch, and the
    /// model id carries the model arg. Discovery adds models; it never opens a raw-prompt bypass.
    @Test @MainActor func discoveredModelIsAGatedGenerationBinding() {
        let (models, _) = MCPModelDiscovery.parseListing(videoListing)
        let byModality = MCPModelDiscovery.generateToolsByModality(higgsfieldTools)
        let entries = MCPModelDiscovery.catalogEntries(
            models: models, toolsByModality: byModality, provider: .higgsfield)
        // Applying discovered MCP models must NOT change `isLoaded` — that tracks the BASE catalog
        // sync only. (Regression: it used to flip true via rebuild(), leaking across tests.)
        let loadedBefore = ModelCatalog.shared.isLoaded
        ModelCatalog.shared.applyDiscovered(entries, for: .higgsfield)
        defer { ModelCatalog.shared.setDiscovered([:]) }
        #expect(ModelCatalog.shared.isLoaded == loadedBefore)

        let bindings = ProviderManifest.bindings(forModelId: "cinematic_studio_3_0")
        #expect(bindings.count == 1)
        let b = try! #require(bindings.first)
        #expect(b.kind == .generation)      // gated path, not an ungated `.tool`
        #expect(b.transport == .mcp)
        #expect(b.provider == .higgsfield)
        #expect(b.providerRef == "generate_video")
        #expect(b.modelParam == "cinematic_studio_3_0")

        // The gate itself rejects a raw prompt for this discovered model, and accepts only a valid token.
        #expect(throws: (any Error).self) {
            try PromptCompiler.enforceGate(args: [:], prompt: "a neon skyline", modelId: "cinematic_studio_3_0")
        }
        let token = PromptCompiler.token(for: "a neon skyline", modelId: "cinematic_studio_3_0")
        #expect(throws: Never.self) {
            try PromptCompiler.enforceGate(
                args: ["compileToken": token], prompt: "a neon skyline", modelId: "cinematic_studio_3_0")
        }
    }
}
