import CoreFoundation
import Foundation
import MCP
import NexGenEngine

/// Turns a provider's runtime MCP discovery into model-catalog entries — the pure, testable core of
/// provider MCP discovery (#163). No I/O: the coordinator (`CatalogDiscovery`) drives the tool
/// calls; everything here is data-in / data-out, so the Tool→CatalogEntry mapping is unit-tested
/// against the providers' real payload shapes without a live account.
///
/// LLM → NGV → Provider stays intact: discovered entries carry an `.mcp` `.generation` offer, so the
/// resolver routes them through the gated `GenerationController` path (compile+token) exactly like the
/// REST providers — discovery adds models, never a raw-prompt bypass.
enum MCPModelDiscovery {
    private static let paginationCursorKeys = [
        "next_page_token", "nextPageToken", "next", "cursor",
    ]
    private static let paginationHasMoreKeys = ["has_more", "hasMore"]
    private static let catalogContentKeys = [
        "items", "models", "job_sets", "jobSets", "model", "job_set", "jobSet",
        "job_set_type", "jobSetType", "model_id", "modelId", "output_type",
        "outputType", "modality",
    ]
    private static let identityFallbackKeys = ["id"]
    private static let operationalEnvelopeKeys = ["status", "action"]
    private static var paginationFieldKeys: [String] {
        paginationCursorKeys + paginationHasMoreKeys
    }
    private static var catalogDetectionKeys: [String] {
        catalogContentKeys + paginationFieldKeys
    }

    enum Modality: String, Sendable, CaseIterable {
        case video, image, audio, upscale
    }

    enum ParsingContext: Sendable {
        case listing
        case detail
    }

    struct ListingParseResult: Sendable {
        let items: [ModelItem]
        let pagination: PaginationEvidence
        let isCatalogPayload: Bool
        let structuralAndDecodeIsComplete: Bool

        var next: String? {
            structuralAndDecodeIsComplete ? pagination.next : nil
        }
        var isComplete: Bool {
            structuralAndDecodeIsComplete && pagination.isComplete
        }
    }

    private enum ListingPayloadResult {
        case catalog(
            items: [Any],
            pagination: PaginationEvidence,
            isStructurallyComplete: Bool
        )
        case notCatalog
    }

    private struct JSONSegment {
        let text: String
        let isBalanced: Bool
    }

    struct PaginationEvidence: Sendable {
        let cursor: String?
        let cursorWasPresent: Bool
        let hasMore: Bool?
        let hasMoreWasPresent: Bool
        let isStructurallyComplete: Bool

        static let none = PaginationEvidence(
            cursor: nil,
            cursorWasPresent: false,
            hasMore: nil,
            hasMoreWasPresent: false,
            isStructurallyComplete: true
        )

        var hasFields: Bool { cursorWasPresent || hasMoreWasPresent }

        var next: String? {
            guard isComplete, hasMore != false else { return nil }
            return cursor
        }

        var isComplete: Bool {
            guard isStructurallyComplete else { return false }
            switch hasMore {
            case true: return cursor != nil
            case false: return cursor == nil
            case nil: return true
            }
        }

        static func aggregating(_ evidence: [PaginationEvidence]) -> PaginationEvidence {
            let cursors = Set(evidence.compactMap(\.cursor))
            let hasMoreValues = Set(evidence.compactMap(\.hasMore))
            return PaginationEvidence(
                cursor: cursors.count == 1 ? cursors.first : nil,
                cursorWasPresent: evidence.contains(where: \.cursorWasPresent),
                hasMore: hasMoreValues.count == 1 ? hasMoreValues.first : nil,
                hasMoreWasPresent: evidence.contains(where: \.hasMoreWasPresent),
                isStructurallyComplete: evidence.allSatisfy(\.isStructurallyComplete)
                    && cursors.count <= 1
                    && hasMoreValues.count <= 1
            )
        }
    }

    // MARK: - Tool classification

    /// Whether a discovered tool *creates* content (vs. edits existing media). Only creators become
    /// catalog models; editors (upscale/outpaint/reframe/remove-background/motion-control) are workflow
    /// `.tool`s reached via `run_provider_tool`, not the model picker.
    static func isGenerative(name: String, description: String?) -> Bool {
        let hay = (name + " " + (description ?? "")).lowercased()
        let signals = ["generate", "create", "text-to", "text2", "txt2", "t2v", "t2i", "i2v", "animate", "synthesi"]
        return signals.contains { hay.contains($0) }
    }

    /// The modality a tool/model serves, by keyword — the same vocabulary dispatch matches on.
    static func modality(name: String, description: String?) -> Modality? {
        let hay = (name + " " + (description ?? "")).lowercased()
        // Order matters: audio/upscale keywords are checked before the broad video/image ones so a
        // "sound" or "upscale" tool isn't mis-bucketed by a stray "image"/"video" token.
        if ["audio", "music", "sound", "speech", "voice", "tts"].contains(where: hay.contains) { return .audio }
        if ["upscale", "super-resolution", "super resolution"].contains(where: hay.contains) { return .upscale }
        if ["video", "animate", "motion", "i2v", "t2v"].contains(where: hay.contains) { return .video }
        if ["image", "picture", "txt2img", "t2i", "img"].contains(where: hay.contains) { return .image }
        return nil
    }

    /// The generate TOOL that serves each modality — the dispatch target (`providerRef`) a discovered
    /// model binds to. First generative match per modality wins; editors are ignored.
    static func generateToolsByModality(_ tools: [MCPProviderClient.DiscoveredTool]) -> [Modality: String] {
        var out: [Modality: String] = [:]
        for tool in tools where isGenerative(name: tool.name, description: tool.description) {
            guard let m = modality(name: tool.name, description: tool.description), out[m] == nil else { continue }
            out[m] = tool.name
        }
        return out
    }

    // MARK: - Model-catalog listing (models_explore-style)

    /// One model as a provider's catalog tool reports it. Every field but `id` is optional so a lean
    /// provider payload still decodes; unknown keys are ignored.
    struct ModelItem: Decodable, Sendable, Equatable {
        let id: String
        let name: String?
        let description: String?
        let outputType: String?
        let aspectRatios: [String]?
        let durations: [Int]?
        let durationRange: SpanRange?
        let parameters: [Param]?
        let medias: [Media]?
        let tags: [String]?
        let constraints: [String]?
        let resolvedMediaTypes: Set<String>

        struct SpanRange: Decodable, Sendable, Equatable { let min: Int?; let max: Int? }
        struct Param: Decodable, Sendable, Equatable {
            let name: String?
            let options: [Scalar]?
            let min: Int?
            let max: Int?

            init(name: String?, options: [Scalar]?, min: Int?, max: Int?) {
                self.name = name
                self.options = options
                self.min = min
                self.max = max
            }

            private enum CodingKeys: String, CodingKey {
                case name, options, min, max
                case minimum
                case maximum
                case minItems = "min_items"
                case maxItems = "max_items"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decodeIfPresent(String.self, forKey: .name)
                options = try c.decodeIfPresent([Scalar].self, forKey: .options)
                min = try c.decodeIfPresent(Int.self, forKey: .min)
                    ?? c.decodeIfPresent(Int.self, forKey: .minimum)
                    ?? c.decodeIfPresent(Int.self, forKey: .minItems)
                max = try c.decodeIfPresent(Int.self, forKey: .max)
                    ?? c.decodeIfPresent(Int.self, forKey: .maximum)
                    ?? c.decodeIfPresent(Int.self, forKey: .maxItems)
            }
        }
        struct Media: Decodable, Sendable, Equatable {
            let name: String?
            let type: String?
            let roles: [String]?
            let min: Int?
            let max: Int?

            init(name: String?, type: String?, roles: [String]?, min: Int?, max: Int?) {
                self.name = name
                self.type = type
                self.roles = roles
                self.min = min
                self.max = max
            }

            private enum CodingKeys: String, CodingKey {
                case name, type, roles, min, max
                case minimum, maximum
                case minItems = "min_items"
                case maxItems = "max_items"
                case minItemsCamel = "minItems"
                case maxItemsCamel = "maxItems"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decodeIfPresent(String.self, forKey: .name)
                type = try c.decodeIfPresent(String.self, forKey: .type)
                roles = try c.decodeIfPresent([String].self, forKey: .roles)
                min = try c.decodeIfPresent(Int.self, forKey: .min)
                    ?? c.decodeIfPresent(Int.self, forKey: .minimum)
                    ?? c.decodeIfPresent(Int.self, forKey: .minItems)
                    ?? c.decodeIfPresent(Int.self, forKey: .minItemsCamel)
                max = try c.decodeIfPresent(Int.self, forKey: .max)
                    ?? c.decodeIfPresent(Int.self, forKey: .maximum)
                    ?? c.decodeIfPresent(Int.self, forKey: .maxItems)
                    ?? c.decodeIfPresent(Int.self, forKey: .maxItemsCamel)
            }
        }
        /// A param option value that may arrive as string / number / bool — normalized to its text.
        struct Scalar: Decodable, Sendable, Equatable {
            let text: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { text = s }
                else if let i = try? c.decode(Int.self) { text = String(i) }
                else if let d = try? c.decode(Double.self) { text = String(d) }
                else if let b = try? c.decode(Bool.self) { text = String(b) }
                else { text = "" }
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, name, description, parameters, medias, tags, constraints, type, modality
            case jobSetType = "job_set_type"
            case jobSetTypeCamel = "jobSetType"
            case modelId = "model_id"
            case modelIdCamel = "modelId"
            case displayName = "display_name"
            case displayNameCamel = "displayName"
            case params
            case mediaInputs = "media_inputs"
            case mediaInputsCamel = "mediaInputs"
            case outputType = "output_type"
            case outputTypeCamel = "outputType"
            case aspectRatios = "aspect_ratios"
            case aspectRatiosCamel = "aspectRatios"
            case durations
            case durationRange = "duration_range"
            case durationRangeCamel = "durationRange"
        }

        init(
            id: String,
            name: String?,
            description: String?,
            outputType: String?,
            aspectRatios: [String]?,
            durations: [Int]?,
            durationRange: SpanRange?,
            parameters: [Param]?,
            medias: [Media]?,
            tags: [String]?,
            constraints: [String]? = nil,
            resolvedMediaTypes: Set<String> = []
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.outputType = outputType
            self.aspectRatios = aspectRatios
            self.durations = durations
            self.durationRange = durationRange
            self.parameters = parameters
            self.medias = medias
            self.tags = tags
            self.constraints = constraints
            self.resolvedMediaTypes = resolvedMediaTypes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
                ?? c.decodeIfPresent(String.self, forKey: .jobSetType)
                ?? c.decodeIfPresent(String.self, forKey: .jobSetTypeCamel)
                ?? c.decodeIfPresent(String.self, forKey: .modelId)
                ?? c.decode(String.self, forKey: .modelIdCamel)
            name = try c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .displayName)
                ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            outputType = try c.decodeIfPresent(String.self, forKey: .outputType)
                ?? c.decodeIfPresent(String.self, forKey: .outputTypeCamel)
                ?? c.decodeIfPresent(String.self, forKey: .type)
                ?? c.decodeIfPresent(String.self, forKey: .modality)
            aspectRatios = try c.decodeIfPresent([String].self, forKey: .aspectRatios)
                ?? c.decodeIfPresent([String].self, forKey: .aspectRatiosCamel)
            durations = try c.decodeIfPresent([Int].self, forKey: .durations)
            durationRange = try c.decodeIfPresent(SpanRange.self, forKey: .durationRange)
                ?? c.decodeIfPresent(SpanRange.self, forKey: .durationRangeCamel)
            parameters = try c.decodeIfPresent([Param].self, forKey: .parameters)
                ?? c.decodeIfPresent([Param].self, forKey: .params)
            medias = try c.decodeIfPresent([Media].self, forKey: .medias)
                ?? c.decodeIfPresent([Media].self, forKey: .mediaInputs)
                ?? c.decodeIfPresent([Media].self, forKey: .mediaInputsCamel)
            tags = try c.decodeIfPresent([String].self, forKey: .tags)
            if !c.contains(.constraints) {
                constraints = nil
            } else {
                let constraintsAreNull = try c.decodeNil(forKey: .constraints)
                if constraintsAreNull {
                    constraints = nil
                } else if let values = try? c.decode([String].self, forKey: .constraints) {
                    constraints = values
                } else {
                    constraints = [try c.decode(String.self, forKey: .constraints)]
                }
            }
            resolvedMediaTypes = []
        }

        func withOutputType(_ fallback: String?) -> ModelItem {
            guard outputType?.isEmpty != false, let fallback else { return self }
            return ModelItem(
                id: id,
                name: name,
                description: description,
                outputType: fallback,
                aspectRatios: aspectRatios,
                durations: durations,
                durationRange: durationRange,
                parameters: parameters,
                medias: medias,
                tags: tags,
                constraints: constraints,
                resolvedMediaTypes: resolvedMediaTypes
            )
        }

        func merging(_ detail: ModelItem, resolvingMediaDetails: Bool) -> ModelItem {
            ModelItem(
                id: id,
                name: detail.name ?? name,
                description: detail.description ?? description,
                outputType: detail.outputType ?? outputType,
                aspectRatios: detail.aspectRatios ?? aspectRatios,
                durations: detail.durations ?? durations,
                durationRange: detail.durationRange ?? durationRange,
                parameters: Self.moreCompleteParameters(parameters, detail.parameters),
                medias: Self.moreCompleteMedia(medias, detail.medias),
                tags: detail.tags ?? tags,
                constraints: Self.mergedStrings(constraints, detail.constraints),
                resolvedMediaTypes: resolvedMediaTypes.union(
                    resolvingMediaDetails ? detail.declaredReferenceMediaTypes : []
                ).union(detail.resolvedMediaTypes)
            )
        }

        func hasResolvedMediaType(_ type: String) -> Bool {
            resolvedMediaTypes.contains(type.lowercased())
        }

        private var declaredReferenceMediaTypes: Set<String> {
            var types = Set((medias ?? []).compactMap { $0.type?.lowercased() })
            for parameter in parameters ?? [] {
                let name = (parameter.name ?? "").lowercased()
                    .replacingOccurrences(of: "_", with: "")
                for type in ["image", "video", "audio"]
                    where name == type || name == "\(type)s" || name == "\(type)references" {
                    types.insert(type)
                }
            }
            for constraint in constraints ?? [] {
                let normalized = constraint.lowercased().replacingOccurrences(of: "_", with: " ")
                for type in ["image", "video", "audio"]
                    where normalized.contains(type) && normalized.contains("reference") {
                    types.insert(type)
                }
            }
            return types
        }

        private static func moreCompleteParameters(
            _ current: [Param]?,
            _ candidate: [Param]?
        ) -> [Param]? {
            var merged: [Param] = []
            var indices: [String: Int] = [:]
            for value in (current ?? []) + (candidate ?? []) {
                let key = (value.name ?? "").lowercased()
                guard !key.isEmpty, let index = indices[key] else {
                    if !key.isEmpty { indices[key] = merged.count }
                    merged.append(value)
                    continue
                }
                let existing = merged[index]
                merged[index] = Param(
                    name: value.name ?? existing.name,
                    options: mergedScalars(existing.options, value.options),
                    min: stricterMinimum(existing.min, value.min),
                    max: stricterMaximum(existing.max, value.max)
                )
            }
            return merged.isEmpty ? nil : merged
        }

        private static func moreCompleteMedia(
            _ current: [Media]?,
            _ candidate: [Media]?
        ) -> [Media]? {
            var merged: [Media] = []
            var indices: [String: Int] = [:]
            for value in (current ?? []) + (candidate ?? []) {
                let name = (value.name ?? "").lowercased()
                let type = (value.type ?? "").lowercased()
                let key = name + "\u{0}" + type
                guard key != "\u{0}", let index = indices[key] else {
                    if key != "\u{0}" { indices[key] = merged.count }
                    merged.append(value)
                    continue
                }
                let existing = merged[index]
                merged[index] = Media(
                    name: value.name ?? existing.name,
                    type: value.type ?? existing.type,
                    roles: mergedStrings(existing.roles, value.roles),
                    min: stricterMinimum(existing.min, value.min),
                    max: stricterMaximum(existing.max, value.max)
                )
            }
            return merged.isEmpty ? nil : merged
        }

        private static func mergedScalars(
            _ lhs: [Scalar]?,
            _ rhs: [Scalar]?
        ) -> [Scalar]? {
            let merged = (lhs ?? []) + (rhs ?? [])
            var seen = Set<String>()
            let unique = merged.filter { seen.insert($0.text).inserted }
            return unique.isEmpty ? nil : unique
        }

        private static func stricterMinimum(_ lhs: Int?, _ rhs: Int?) -> Int? {
            switch (lhs, rhs) {
            case (.some(let lhs), .some(let rhs)): Swift.max(lhs, rhs)
            case (.some(let value), .none), (.none, .some(let value)): value
            case (.none, .none): nil
            }
        }

        private static func stricterMaximum(_ lhs: Int?, _ rhs: Int?) -> Int? {
            switch (lhs, rhs) {
            case (.some(let lhs), .some(let rhs)): Swift.min(lhs, rhs)
            case (.some(let value), .none), (.none, .some(let value)): value
            case (.none, .none): nil
            }
        }

        private static func mergedStrings(_ lhs: [String]?, _ rhs: [String]?) -> [String]? {
            let merged = (lhs ?? []) + (rhs ?? [])
            var seen = Set<String>()
            let unique = merged.filter { seen.insert($0).inserted }
            return unique.isEmpty ? nil : unique
        }
    }

    static func parseListing(
        _ text: String,
        defaultOutputType: String? = nil,
        context: ParsingContext = .listing
    ) -> (items: [ModelItem], next: String?) {
        let result = parseListingResult(
            text,
            defaultOutputType: defaultOutputType,
            context: context
        )
        return (result.items, result.next)
    }

    /// Parse one catalog-tool content block and report any structural or model-decoding loss.
    static func parseListingResult(
        _ text: String,
        defaultOutputType: String? = nil,
        context: ParsingContext = .listing
    ) -> ListingParseResult {
        let segments = jsonSegments(in: text)
        let hasUnbalancedJSONSegment = segments.contains { !$0.isBalanced }
        var rawItems: [Any] = []
        var paginationEvidence: [PaginationEvidence] = []
        var isCatalogPayload = false
        var structuralAndDecodeIsComplete = true
        for segment in segments {
            guard segment.isBalanced,
                  let data = segment.text.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else {
                if looksLikeCatalogPayload(
                    segment.text,
                    defaultOutputType: defaultOutputType,
                    context: context
                ) {
                    isCatalogPayload = true
                    structuralAndDecodeIsComplete = false
                }
                continue
            }
            guard case .catalog(
                let items,
                let pagination,
                let payloadIsStructurallyComplete
            ) = listingPayload(
                root,
                context: context
            ) else { continue }
            isCatalogPayload = true
            rawItems.append(contentsOf: items)
            paginationEvidence.append(pagination)
            structuralAndDecodeIsComplete = structuralAndDecodeIsComplete
                && payloadIsStructurallyComplete
        }
        if isCatalogPayload && hasUnbalancedJSONSegment {
            structuralAndDecodeIsComplete = false
        }
        guard isCatalogPayload else {
            return ListingParseResult(
                items: [],
                pagination: .none,
                isCatalogPayload: false,
                structuralAndDecodeIsComplete: true
            )
        }
        let pagination = PaginationEvidence.aggregating(paginationEvidence)
        let decoder = JSONDecoder()
        var items: [ModelItem] = []
        for value in rawItems {
            guard let decoded = decodedModelItem(from: value, decoder: decoder) else {
                structuralAndDecodeIsComplete = false
                continue
            }
            items.append(decoded.withOutputType(defaultOutputType))
        }
        return ListingParseResult(
            items: items,
            pagination: pagination,
            isCatalogPayload: true,
            structuralAndDecodeIsComplete: structuralAndDecodeIsComplete
        )
    }

    private static func jsonSegments(in text: String) -> [JSONSegment] {
        var segments: [JSONSegment] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let start = text[searchStart...].firstIndex(where: {
                $0 == "{" || $0 == "["
              }) {
            var expectedClosers: [Character] = []
            var quote: Character?
            var isEscaped = false
            var index = start
            var foundEnd = false
            while index < text.endIndex {
                let character = text[index]
                if let activeQuote = quote {
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == activeQuote {
                        quote = nil
                    }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "{" {
                    expectedClosers.append("}")
                } else if character == "[" {
                    expectedClosers.append("]")
                } else if character == "}" || character == "]" {
                    let after = text.index(after: index)
                    guard expectedClosers.last == character else {
                        segments.append(JSONSegment(
                            text: String(text[start..<after]),
                            isBalanced: false
                        ))
                        searchStart = after
                        foundEnd = true
                        break
                    }
                    expectedClosers.removeLast()
                    if expectedClosers.isEmpty {
                        segments.append(JSONSegment(
                            text: String(text[start..<after]),
                            isBalanced: true
                        ))
                        searchStart = after
                        foundEnd = true
                        break
                    }
                }
                index = text.index(after: index)
            }
            if !foundEnd {
                segments.append(JSONSegment(
                    text: String(text[start...]),
                    isBalanced: false
                ))
                break
            }
        }
        return segments
    }

    private static func looksLikeCatalogPayload(
        _ text: String,
        defaultOutputType: String?,
        context: ParsingContext
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return false }
        if containsCatalogKeyToken(in: trimmed) { return true }
        let isOperationalEnvelope = containsObjectKeyToken(
            in: trimmed,
            aliases: operationalEnvelopeKeys
        )
        let hasIdentityFallback = containsObjectKeyToken(
            in: trimmed,
            aliases: identityFallbackKeys
        )
        return (context == .detail || defaultOutputType != nil)
            && (trimmed.first == "[" || (trimmed.first == "{" && !isOperationalEnvelope))
            && hasIdentityFallback
    }

    private static func containsCatalogKeyToken(in text: String) -> Bool {
        containsObjectKeyToken(in: text, aliases: catalogDetectionKeys)
    }

    private static func containsObjectKeyToken(
        in text: String,
        aliases: [String]
    ) -> Bool {
        let aliases = Set(aliases.map { $0.lowercased() })
        var quote: Character?
        var isEscaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "{" || character == "," {
                let after = text.index(after: index)
                if let key = objectKey(in: text, startingAt: after),
                   aliases.contains(key.lowercased()) {
                    return true
                }
            }
            index = text.index(after: index)
        }
        return false
    }

    private static func objectKey(
        in text: String,
        startingAt start: String.Index
    ) -> String? {
        var index = start
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return nil }
        let key: String
        if text[index] == "\"" || text[index] == "'" {
            let quote = text[index]
            let keyStart = text.index(after: index)
            index = keyStart
            var isEscaped = false
            while index < text.endIndex {
                let character = text[index]
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == quote {
                    break
                }
                index = text.index(after: index)
            }
            guard index < text.endIndex else { return nil }
            key = String(text[keyStart..<index])
            index = text.index(after: index)
        } else {
            let keyStart = index
            while index < text.endIndex {
                let character = text[index]
                guard character.isLetter || character.isNumber || character == "_" else {
                    break
                }
                index = text.index(after: index)
            }
            guard index > keyStart else { return nil }
            key = String(text[keyStart..<index])
        }
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == ":" else { return nil }
        return key
    }

    private static func listingPayload(
        _ value: Any,
        context: ParsingContext
    ) -> ListingPayloadResult {
        if let array = value as? [Any] {
            let containsModel = array.contains { value in
                guard let object = value as? [String: Any] else { return false }
                return hasStandaloneModelContract(object, context: context)
                    && decodedModelItem(from: object) != nil
            }
            guard containsModel else { return .notCatalog }
            return .catalog(
                items: array,
                pagination: .none,
                isStructurallyComplete: true
            )
        }
        guard let object = value as? [String: Any] else { return .notCatalog }
        let pagination = paginationMetadata(in: object)
        var nestedItems: [Any] = []
        var nestedPagination: [PaginationEvidence] = []
        var foundNestedCatalog = false
        var nestedIsStructurallyComplete = true
        for key in ["data", "result", "payload"] {
            guard let nested = object[key],
                  case .catalog(
                    let items,
                    let evidence,
                    let isStructurallyComplete
                  ) = listingPayload(
                    nested,
                    context: context
                  ) else { continue }
            foundNestedCatalog = true
            nestedItems.append(contentsOf: items)
            nestedPagination.append(evidence)
            nestedIsStructurallyComplete = nestedIsStructurallyComplete
                && isStructurallyComplete
        }
        let combinedPagination = PaginationEvidence.aggregating(
            [pagination] + nestedPagination
        )

        let collectionKeys = ["items", "models", "job_sets", "jobSets"]
        let presentCollections = collectionKeys.filter { object[$0] != nil }
        if !presentCollections.isEmpty {
            var items: [Any] = []
            var isStructurallyComplete = combinedPagination.isStructurallyComplete
                && (!foundNestedCatalog || nestedIsStructurallyComplete)
            for key in presentCollections {
                guard let values = object[key] as? [Any] else {
                    isStructurallyComplete = false
                    continue
                }
                items.append(contentsOf: values)
            }
            return .catalog(
                items: items,
                pagination: combinedPagination,
                isStructurallyComplete: isStructurallyComplete
            )
        }

        let singleKeys = ["model", "job_set", "jobSet"]
        let presentSingles = singleKeys.filter { object[$0] != nil }
        if !presentSingles.isEmpty {
            var items: [Any] = []
            var isStructurallyComplete = combinedPagination.isStructurallyComplete
                && (!foundNestedCatalog || nestedIsStructurallyComplete)
            for key in presentSingles {
                guard let item = object[key] as? [String: Any],
                      hasStandaloneModelContract(item, context: context) else {
                    isStructurallyComplete = false
                    continue
                }
                items.append(item)
            }
            return .catalog(
                items: items,
                pagination: combinedPagination,
                isStructurallyComplete: isStructurallyComplete
            )
        }

        if ["id", "job_set_type", "jobSetType", "model_id", "modelId"]
            .contains(where: { object[$0] != nil }),
           hasStandaloneModelContract(object, context: context) {
            return .catalog(
                items: [object],
                pagination: combinedPagination,
                isStructurallyComplete: combinedPagination.isStructurallyComplete
                    && (!foundNestedCatalog || nestedIsStructurallyComplete)
            )
        }
        if foundNestedCatalog {
            return .catalog(
                items: nestedItems,
                pagination: combinedPagination,
                isStructurallyComplete: combinedPagination.isStructurallyComplete
                    && nestedIsStructurallyComplete
            )
        }
        if combinedPagination.hasFields {
            return .catalog(
                items: [],
                pagination: combinedPagination,
                isStructurallyComplete: combinedPagination.isStructurallyComplete
            )
        }
        return .notCatalog
    }

    private static func decodedModelItem(
        from value: Any,
        decoder: JSONDecoder = JSONDecoder()
    ) -> ModelItem? {
        guard let object = value as? [String: Any],
              !isOperationalEnvelope(object),
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? decoder.decode(ModelItem.self, from: data),
              !decoded.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return decoded
    }

    private static func paginationMetadata(
        in object: [String: Any]
    ) -> PaginationEvidence {
        let cursorWasPresent = paginationCursorKeys.contains { object[$0] != nil }
        let hasMoreWasPresent = paginationHasMoreKeys.contains { object[$0] != nil }
        var isComplete = true
        var cursors = Set<String>()
        for key in paginationCursorKeys where object[key] != nil {
            guard let value = object[key] else { continue }
            if value is NSNull { continue }
            guard let cursor = value as? String,
                  !cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                isComplete = false
                continue
            }
            cursors.insert(cursor)
        }
        if cursors.count > 1 { isComplete = false }

        var moreValues = Set<Bool>()
        for key in paginationHasMoreKeys where object[key] != nil {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else {
                isComplete = false
                continue
            }
            moreValues.insert(number.boolValue)
        }
        if moreValues.count > 1 { isComplete = false }
        let hasMore = moreValues.count == 1 ? moreValues.first : nil
        let cursor = cursors.count == 1 ? cursors.first : nil
        return PaginationEvidence(
            cursor: cursor,
            cursorWasPresent: cursorWasPresent,
            hasMore: hasMore,
            hasMoreWasPresent: hasMoreWasPresent,
            isStructurallyComplete: isComplete
        )
    }

    private static func hasStandaloneModelContract(
        _ object: [String: Any],
        context: ParsingContext
    ) -> Bool {
        guard hasValidModelIdentity(object), !isOperationalEnvelope(object) else {
            return false
        }
        if context == .detail { return true }
        if hasDeclaredOutputModality(object) { return true }
        let hasJobSetIdentity = ["job_set_type", "jobSetType"].contains { key in
            guard let value = object[key] as? String else { return false }
            return !value.isEmpty
        }
        return hasJobSetIdentity && hasGenericTypeModality(object)
    }

    private static func hasValidModelIdentity(_ object: [String: Any]) -> Bool {
        ["id", "job_set_type", "jobSetType", "model_id", "modelId"].contains { key in
            guard let value = object[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func hasDeclaredOutputModality(_ object: [String: Any]) -> Bool {
        for key in ["output_type", "outputType", "modality"] {
            guard let raw = object[key] as? String else { continue }
            if Modality(rawValue: raw.lowercased()) != nil { return true }
        }
        return false
    }

    private static func hasGenericTypeModality(_ object: [String: Any]) -> Bool {
        guard let raw = object["type"] as? String else { return false }
        return Modality(rawValue: raw.lowercased()) != nil
    }

    private static func isOperationalEnvelope(_ object: [String: Any]) -> Bool {
        object["action"] != nil || object["status"] != nil
    }

    // MARK: - Mapping (the unit-tested core)

    static func resolveOfferingCapabilities(
        models: [ModelItem],
        toolsByModality: [Modality: String],
        provider: GenerationProvider,
        resolver: ModelCapabilityResolver,
        observedAt: String
    ) throws -> [String: ResolvedOfferingCapabilityProfileV1] {
        var result: [String: ResolvedOfferingCapabilityProfileV1] = [:]
        for model in models {
            guard let modality = modalityOf(model),
                  let capabilityModality = capabilityModality(modality),
                  let endpointID = toolsByModality[modality] else { continue }
            let qualifiedModelID = "\(provider.rawValue)/\(model.id)"
            let offering = CapabilityOfferingIdentityV1(
                providerID: provider.rawValue,
                offeringID: "\(provider.rawValue)/\(endpointID)/\(model.id)",
                endpointID: endpointID,
                catalogModelID: qualifiedModelID,
                modality: capabilityModality
            )
            let evidence = CapabilityEvidenceV1(
                sourceTitle: "\(provider.displayName) runtime endpoint schema",
                observedAt: observedAt,
                kind: .providerSchema,
                confidence: 1
            )
            let overlay = EndpointCapabilityOverlayV1(
                offering: offering,
                schemaEvidence: [evidence],
                restrictions: endpointRestrictions(
                    model,
                    modality: modality,
                    evidence: evidence
                ),
                arrayConstraints: endpointArrayConstraints(
                    model,
                    modality: modality
                )
            )
            result[model.id] = try resolver.resolveOffering(
                offering,
                lookup: CapabilityLookupV1(
                    modality: capabilityModality,
                    catalogModelID: qualifiedModelID
                ),
                overlay: overlay
            )
        }
        return result
    }

    /// Map a provider's enumerated models onto catalog entries, one per model, each bound to the
    /// generate tool of its modality. A model whose modality has no discovered generate tool is
    /// dropped (nothing could dispatch it). This is the pure Tool→CatalogEntry contract.
    static func catalogEntries(
        models: [ModelItem],
        toolsByModality: [Modality: String],
        toolSchemasByModality: [Modality: Value] = [:],
        allowsLocalMedia: Bool = true,
        resolvedCapabilities: [String: ResolvedOfferingCapabilityProfileV1] = [:],
        provider: GenerationProvider
    ) -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        var seen = Set<String>()
        for model in models {
            guard !model.id.isEmpty, !seen.contains(model.id) else { continue }
            guard let modality = modalityOf(model), let tool = toolsByModality[modality] else { continue }
            if let schema = toolSchemasByModality[modality],
               !generationSchemaSupports(
                   model: model, modality: modality, schema: schema, modelParam: model.id,
                   includeMedia: allowsLocalMedia
               ) {
                continue
            }
            seen.insert(model.id)
            let offer = ProviderOffer(provider: provider, transport: .mcp,
                                      providerRef: tool, modelParam: model.id,
                                      mcpMediaRoles: allowsLocalMedia
                                        ? Array(mediaRoles(model)).sorted() : [])
            out.append(entry(
                for: model, modality: modality, offer: offer,
                allowsLocalMedia: allowsLocalMedia,
                capabilityProfile: resolvedCapabilities[model.id]
            ))
        }
        return out
    }

    /// A generate tool with no separate model catalog (its `model` is a single implicit choice, or the
    /// provider advertises no catalog): one entry per discovered generate tool, dispatched by tool name
    /// with no `model` argument. The fallback when a provider has no `mcpModelCatalog` hint.
    static func catalogEntriesFromTools(
        _ tools: [MCPProviderClient.DiscoveredTool],
        provider: GenerationProvider
    ) -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        for (modality, tool) in generateToolsByModality(tools).sorted(by: { $0.value < $1.value })
        where modality != .upscale {
            guard let discoveredTool = tools.first(where: { $0.name == tool }) else { continue }
            let item = ModelItem(id: tool, name: "\(provider.displayName) \(modality.rawValue.capitalized)",
                                 description: discoveredTool.description,
                                 outputType: modality.rawValue, aspectRatios: nil, durations: nil,
                                 durationRange: nil, parameters: nil, medias: nil, tags: nil)
            guard generationSchemaSupports(
                model: item,
                modality: modality,
                schema: discoveredTool.inputSchema,
                modelParam: nil,
                includeMedia: false
            ) else { continue }
            let offer = ProviderOffer(provider: provider, transport: .mcp, providerRef: tool, modelParam: nil)
            out.append(entry(for: item, modality: modality, offer: offer, allowsLocalMedia: false))
        }
        return out
    }

    // MARK: - Entry construction

    static func modalityOf(_ model: ModelItem) -> Modality? {
        switch (model.outputType ?? "").lowercased() {
        case "video": return .video
        case "image": return .image
        case "audio": return .audio
        case "upscale": return .upscale
        default: return nil   // "3d" and unknowns have no ModelKind — skip
        }
    }

    private static func capabilityModality(_ modality: Modality) -> CapabilityModalityV1? {
        switch modality {
        case .video: return .video
        case .image: return .image
        case .audio: return .audio
        case .upscale: return nil
        }
    }

    private static func endpointArrayConstraints(
        _ model: ModelItem,
        modality: Modality
    ) -> [String: EndpointArrayConstraintV1] {
        switch modality {
        case .video:
            return [
                CapabilityFieldIDV1.referenceImages: endpointArrayConstraint(
                    model,
                    mediaType: "image"
                ),
                CapabilityFieldIDV1.referenceVideos: endpointArrayConstraint(
                    model,
                    mediaType: "video"
                ),
                CapabilityFieldIDV1.referenceAudios: endpointArrayConstraint(
                    model,
                    mediaType: "audio"
                ),
            ]
        case .image:
            return [
                CapabilityFieldIDV1.imageReferences: endpointArrayConstraint(
                    model,
                    mediaType: "image"
                ),
            ]
        case .audio, .upscale:
            return [:]
        }
    }

    private static func endpointArrayConstraint(
        _ model: ModelItem,
        mediaType: String
    ) -> EndpointArrayConstraintV1 {
        let medias = referenceMedia(model, type: mediaType)
        let parameter = referenceParameter(model, type: mediaType)
        let constraintMaximum = constraintMaximum(model, mediaType: mediaType)
        let mediaMaximum = !medias.isEmpty && medias.allSatisfy { $0.max != nil }
            ? medias.reduce(0) { $0 + Swift.max(0, $1.max ?? 0) }
            : nil
        return EndpointArrayConstraintV1(
            isPresent: !medias.isEmpty || parameter != nil || constraintMaximum != nil,
            maxItems: [constraintMaximum, parameter?.max, mediaMaximum]
                .compactMap { $0 }
                .min()
        )
    }

    private static func endpointRestrictions(
        _ model: ModelItem,
        modality: Modality,
        evidence: CapabilityEvidenceV1
    ) -> EndpointCapabilityRestrictionsV1 {
        var integers: [String: EndpointIntegerRestrictionV1] = [:]
        var decimals: [String: EndpointDecimalRestrictionV1] = [:]
        var strings: [String: EndpointStringListRestrictionV1] = [:]
        var integerLists: [String: EndpointIntegerListRestrictionV1] = [:]

        if let aspectRatios = model.aspectRatios?.filter({ !$0.isEmpty }) {
            strings[CapabilityFieldIDV1.aspectRatios] = EndpointStringListRestrictionV1(
                values: Array(Set(aspectRatios)).sorted(),
                evidence: [evidence]
            )
        }
        if let resolutions = options(model, param: "resolution"), !resolutions.isEmpty {
            strings[CapabilityFieldIDV1.resolutions] = EndpointStringListRestrictionV1(
                values: Array(Set(resolutions)).sorted(),
                evidence: [evidence]
            )
        }
        if modality == .video {
            if let minimum = model.durationRange?.min {
                decimals[CapabilityFieldIDV1.durationMinimum] = EndpointDecimalRestrictionV1(
                    value: Double(minimum),
                    operation: .minimum,
                    evidence: [evidence]
                )
            }
            if let maximum = model.durationRange?.max {
                decimals[CapabilityFieldIDV1.durationMaximum] = EndpointDecimalRestrictionV1(
                    value: Double(maximum),
                    operation: .maximum,
                    evidence: [evidence]
                )
            }
            if let durations = model.durations, !durations.isEmpty {
                integerLists[CapabilityFieldIDV1.durationValues] =
                    EndpointIntegerListRestrictionV1(
                        values: Array(Set(durations)).sorted(),
                        evidence: [evidence]
                    )
            }
        }
        if modality == .image,
           let maximum = outputImageParameterMaximum(model) {
            integers[CapabilityFieldIDV1.imageOutputsPerRequest] =
                EndpointIntegerRestrictionV1(
                    value: maximum,
                    operation: .maximum,
                    evidence: [evidence]
                )
        }
        return EndpointCapabilityRestrictionsV1(
            integers: integers,
            decimals: decimals,
            strings: strings,
            integerLists: integerLists
        )
    }

    private static func outputImageParameterMaximum(_ model: ModelItem) -> Int? {
        let names = Set(["batch_size", "num_images", "number_of_images"])
        return model.parameters?
            .filter { names.contains(($0.name ?? "").lowercased()) }
            .flatMap { parameter -> [Int] in
                var values = (parameter.options ?? []).compactMap { Int($0.text) }
                if let maximum = parameter.max { values.append(maximum) }
                return values
            }
            .max()
    }

    private static func entry(
        for model: ModelItem,
        modality: Modality,
        offer: ProviderOffer,
        allowsLocalMedia: Bool,
        capabilityProfile: ResolvedOfferingCapabilityProfileV1? = nil
    ) -> CatalogEntry {
        let displayName = model.name?.isEmpty == false ? model.name! : model.id
        let card = ModelCard(strengths: nil, weaknesses: nil, bestFor: model.description,
                             rank: nil, tags: model.tags)
        switch modality {
        case .video:
            return CatalogEntry(
                id: model.id, kind: .video, displayName: displayName,
                allowedEndpoints: [model.id], responseShape: .video,
                uiCapabilities: .video(videoCaps(
                    model,
                    allowsLocalMedia: allowsLocalMedia,
                    capabilityProfile: capabilityProfile?.effective
                )),
                card: card,
                offers: [offer],
                resolvedOfferingCapabilities: capabilityProfile.map { [$0] })
        case .image:
            return CatalogEntry(
                id: model.id, kind: .image, displayName: displayName,
                allowedEndpoints: [model.id], responseShape: .images,
                uiCapabilities: .image(imageCaps(
                    model,
                    allowsLocalMedia: allowsLocalMedia,
                    capabilityProfile: capabilityProfile?.effective
                )),
                card: card,
                offers: [offer],
                resolvedOfferingCapabilities: capabilityProfile.map { [$0] })
        case .audio:
            return CatalogEntry(
                id: model.id, kind: .audio, displayName: displayName,
                allowedEndpoints: [model.id], responseShape: .audio,
                uiCapabilities: .audio(audioCaps(model)),
                card: card,
                offers: [offer],
                resolvedOfferingCapabilities: capabilityProfile.map { [$0] })
        case .upscale:
            return CatalogEntry(
                id: model.id, kind: .upscale, displayName: displayName,
                allowedEndpoints: [model.id], responseShape: .upscaledImage,
                uiCapabilities: .upscale(UpscaleCaps(speed: "Medium", p75DurationSeconds: 60,
                                                     supportedTypes: ["image", "video"])),
                card: card,
                offers: [offer],
                resolvedOfferingCapabilities: capabilityProfile.map { [$0] })
        }
    }

    private static func videoCaps(
        _ model: ModelItem,
        allowsLocalMedia: Bool,
        capabilityProfile: ResolvedCapabilityProfileV1?
    ) -> VideoCaps {
        let roles = allowsLocalMedia ? mediaRoles(model) : []
        let imageBounds = allowsLocalMedia
            ? mediaBounds(
                model,
                type: "image",
                intrinsicMaximum: integerCapability(
                    capabilityProfile,
                    field: CapabilityFieldIDV1.referenceImages
                )
            ) : .none
        let videoBounds = allowsLocalMedia
            ? mediaBounds(
                model,
                type: "video",
                intrinsicMaximum: integerCapability(
                    capabilityProfile,
                    field: CapabilityFieldIDV1.referenceVideos
                )
            ) : .none
        let audioBounds = allowsLocalMedia
            ? mediaBounds(
                model,
                type: "audio",
                intrinsicMaximum: integerCapability(
                    capabilityProfile,
                    field: CapabilityFieldIDV1.referenceAudios
                )
            ) : .none
        let derivedTotalMaximum = [imageBounds, videoBounds, audioBounds]
            .allSatisfy(\.isEffectivelyBounded)
            ? imageBounds.max + videoBounds.max + audioBounds.max
            : nil
        let endpointTotalMaximum = constraintMaximum(model, mediaType: "total")
        let intrinsicTotalMaximum = integerCapability(
            capabilityProfile,
            field: CapabilityFieldIDV1.totalReferences
        )
        let hasReferenceArgument = imageBounds.declared
            || videoBounds.declared
            || audioBounds.declared
        let totalMaximum = hasReferenceArgument
            ? [endpointTotalMaximum, intrinsicTotalMaximum, derivedTotalMaximum]
                .compactMap { $0 }
                .min()
            : nil
        let conditionalImageMaximum = conditionalConstraintMaximum(
            model,
            mediaType: "image",
            whenReferenceType: "video"
        ).map { endpointMaximum in
            integerCapability(
                capabilityProfile,
                field: CapabilityFieldIDV1.referenceImages
            ).map { Swift.min(endpointMaximum, $0) } ?? endpointMaximum
        }
        return VideoCaps(
            durations: model.durations ?? [],
            durationRange: durationRange(model.durationRange),
            supportsAutomaticDuration: supportsAutomaticDuration(model),
            resolutions: options(model, param: "resolution"),
            aspectRatios: aspectRatios(model),
            supportsFirstFrame: roles.contains("start_image"),
            supportsLastFrame: roles.contains("end_image"),
            maxReferenceImages: imageBounds.max,
            maxReferenceVideos: videoBounds.max, maxReferenceAudios: audioBounds.max,
            maxTotalReferences: totalMaximum,
            maxCombinedVideoRefSeconds: nil, maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false, referenceTagNoun: "image",
            requiresSourceVideo: false, requiresReferenceImage: imageBounds.min > 0,
            framesCountTowardImageReferenceLimit: framesCountTowardImageReferenceLimit(model),
            framesCountTowardTotalReferenceLimit: framesCountTowardTotalReferenceLimit(model),
            maxReferenceImagesWhenVideoPresent: conditionalImageMaximum)
    }

    private static func imageCaps(
        _ model: ModelItem,
        allowsLocalMedia: Bool,
        capabilityProfile: ResolvedCapabilityProfileV1?
    ) -> ImageCaps {
        let intrinsicReferences = integerCapability(
            capabilityProfile,
            field: CapabilityFieldIDV1.imageReferences
        )
        let bounds = allowsLocalMedia
            ? mediaBounds(
                model,
                type: "image",
                intrinsicMaximum: intrinsicReferences
            ) : .none
        let referenceLimit = allowsLocalMedia
            ? imageReferenceLimit(model, intrinsicMaximum: intrinsicReferences) : .bounded(0)
        return ImageCaps(
            resolutions: options(model, param: "resolution"),
            aspectRatios: aspectRatios(model),
            qualities: options(model, param: "quality") ?? options(model, param: "mode"),
            supportsImageReference: referenceLimit.effectiveMaximum > 0,
            requiresImageReference: bounds.min > 0,
            minReferenceImages: bounds.min,
            referenceImageLimit: referenceLimit,
            maxImages: maxOutputImages(model, capabilityProfile: capabilityProfile))
    }

    private static func audioCaps(_ model: ModelItem) -> AudioCaps {
        let tags = (model.tags ?? []).map { $0.lowercased() }
        let acceptsVideo = hasMedia(model, type: "video")
        let category: String
        if tags.contains(where: { $0.contains("music") }) { category = "music" }
        else if tags.contains(where: { $0.contains("sfx") || $0.contains("sound-effect") }) { category = "sfx" }
        else { category = "tts" }
        let span = expandedRange(model.durationRange)
        return AudioCaps(
            category: category, voices: nil, defaultVoice: nil,
            supportsLyrics: category == "music", supportsInstrumental: category == "music",
            supportsStyleInstructions: false,
            durations: model.durations,
            minPromptLength: acceptsVideo ? 0 : 1,
            inputs: acceptsVideo ? ["text", "video"] : ["text"],
            promptLabel: nil,
            minSeconds: span.first, maxSeconds: span.last)
    }

    // MARK: - Field helpers

    private static func aspectRatios(_ model: ModelItem) -> [String] {
        (model.aspectRatios ?? []).filter { $0.lowercased() != "auto" }
    }

    private static func durationRange(_ range: ModelItem.SpanRange?) -> VideoDurationCapabilities.Range? {
        guard let min = range?.min, let max = range?.max, min <= max else { return nil }
        return .init(min: min, max: max)
    }

    private static func supportsAutomaticDuration(_ model: ModelItem) -> Bool {
        model.parameters?
            .first { ($0.name ?? "").lowercased() == "duration" }?
            .options?
            .contains { $0.text.lowercased() == "auto" } == true
    }

    /// A `{min,max}` range → an inclusive list of second-choices, capped so an unbounded range never
    /// balloons the picker (beyond the cap only the two anchors are offered).
    private static func expandedRange(_ range: ModelItem.SpanRange?) -> [Int] {
        guard let lo = range?.min, let hi = range?.max, lo <= hi else { return [] }
        if hi - lo > 30 { return [lo, hi] }
        return Array(lo...hi)
    }

    private static func options(_ model: ModelItem, param: String) -> [String]? {
        guard let opts = model.parameters?.first(where: { ($0.name ?? "") == param })?.options, !opts.isEmpty
        else { return nil }
        let texts = opts.map(\.text).filter { !$0.isEmpty && $0.lowercased() != "auto" }
        return texts.isEmpty ? nil : texts
    }

    private static func mediaRoles(_ model: ModelItem) -> Set<String> {
        Set((model.medias ?? []).flatMap { $0.roles ?? [] }.map { $0.lowercased() })
    }

    private static func hasImageMedia(_ model: ModelItem) -> Bool {
        hasMedia(model, type: "image")
    }

    private static func hasMedia(_ model: ModelItem, type: String) -> Bool {
        (model.medias ?? []).contains { ($0.type ?? "").lowercased() == type }
    }

    private struct MediaBounds {
        let min: Int
        let max: Int
        let declaredMaximum: Int?
        let declared: Bool
        let isEffectivelyBounded: Bool

        static let none = MediaBounds(
            min: 0,
            max: 0,
            declaredMaximum: nil,
            declared: false,
            isEffectivelyBounded: true
        )
    }

    private static func mediaBounds(
        _ model: ModelItem,
        type: String,
        intrinsicMaximum: Int?
    ) -> MediaBounds {
        let medias = referenceMedia(model, type: type)
        let parameter = referenceParameter(model, type: type)
        let constraintMax = constraintMaximum(model, mediaType: type)
        let mediaMax = !medias.isEmpty && medias.allSatisfy { $0.max != nil }
            ? medias.reduce(0) { $0 + Swift.max(0, $1.max ?? 0) }
            : nil
        let declaredMaximum = [constraintMax, parameter?.max, mediaMax]
            .compactMap { $0 }
            .min()
        let declared = !medias.isEmpty || parameter != nil || constraintMax != nil
        let minimum = Swift.max(
            medias.reduce(0) { $0 + Swift.max(0, $1.min ?? 0) },
            Swift.max(0, parameter?.min ?? 0)
        )
        let maximum: Int
        if let declaredMaximum {
            maximum = Swift.max(
                0,
                intrinsicMaximum.map { Swift.min(declaredMaximum, $0) }
                    ?? declaredMaximum
            )
        } else if declared,
                  model.hasResolvedMediaType(type),
                  let intrinsicMaximum {
            maximum = Swift.max(0, intrinsicMaximum)
        } else {
            maximum = 0
        }
        return MediaBounds(
            min: minimum,
            max: maximum,
            declaredMaximum: declaredMaximum,
            declared: declared,
            isEffectivelyBounded: !declared
                || declaredMaximum != nil
                || intrinsicMaximum != nil
        )
    }

    private static func imageReferenceLimit(
        _ model: ModelItem,
        intrinsicMaximum: Int?
    ) -> ImageReferenceLimit {
        let bounds = mediaBounds(
            model,
            type: "image",
            intrinsicMaximum: intrinsicMaximum
        )
        guard bounds.declared else { return .bounded(0) }
        if bounds.declaredMaximum != nil { return .bounded(bounds.max) }
        guard model.hasResolvedMediaType("image") else { return .unknown }
        guard intrinsicMaximum != nil else { return .unknown }
        return .capabilityProfile(bounds.max)
    }

    private static func referenceMedia(_ model: ModelItem, type: String) -> [ModelItem.Media] {
        let genericRoles: Set<String>
        switch type {
        case "image": genericRoles = ["image", "image_references"]
        case "video": genericRoles = ["video", "video_references"]
        case "audio": genericRoles = ["audio", "audio_references"]
        default: return []
        }
        return (model.medias ?? []).filter { media in
            guard (media.type ?? "").lowercased() == type else { return false }
            let roles = Set((media.roles ?? []).map { $0.lowercased() })
            let name = (media.name ?? "").lowercased()
            return roles.isEmpty
                ? name.isEmpty || genericRoles.contains(name)
                : !roles.isDisjoint(with: genericRoles)
        }
    }

    private static func referenceParameter(
        _ model: ModelItem,
        type: String
    ) -> ModelItem.Param? {
        let names = Set([type, "\(type)s", "\(type)_references", "\(type)references"])
        return model.parameters?.first {
            guard let name = $0.name?.lowercased() else { return false }
            return names.contains(name) || names.contains(name.replacingOccurrences(of: "_", with: ""))
        }
    }

    private static func constraintMaximum(_ model: ModelItem, mediaType: String) -> Int? {
        let constraints = model.constraints ?? []
        var maxima: [Int] = []
        for value in constraints {
            let normalized = value.lowercased().replacingOccurrences(of: "_", with: " ")
            guard !isConditionalConstraint(normalized) else { continue }
            let concernsType: Bool
            if mediaType == "total" {
                concernsType = normalized.contains("reference")
                    && (normalized.contains("total") || normalized.contains("across"))
            } else {
                concernsType = normalized.contains(mediaType)
                    && normalized.contains("reference")
                    && !isAggregateTotalConstraint(normalized)
            }
            guard concernsType else { continue }
            if let maximum = declaredMaximum(in: normalized) { maxima.append(maximum) }
        }
        return maxima.min()
    }

    private static func conditionalConstraintMaximum(
        _ model: ModelItem,
        mediaType: String,
        whenReferenceType: String
    ) -> Int? {
        (model.constraints ?? []).compactMap { value -> Int? in
            let normalized = value.lowercased().replacingOccurrences(of: "_", with: " ")
            guard isConditionalConstraint(normalized),
                  normalized.contains(mediaType),
                  normalized.contains("reference"),
                  normalized.contains(whenReferenceType) else { return nil }
            return declaredMaximum(in: normalized)
        }.min()
    }

    private static func declaredMaximum(in normalized: String) -> Int? {
        if normalized.contains("exactly one") || normalized.contains("at most one") {
            return 1
        }
        guard normalized.contains("at most")
                || normalized.contains("maximum")
                || normalized.contains("up to") else { return nil }
        return normalized.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
    }

    private static func isConditionalConstraint(_ normalized: String) -> Bool {
        normalized.contains("when ")
            || normalized.contains(" if ")
            || normalized.hasPrefix("if ")
            || normalized.contains("provided,")
    }

    private static func isAggregateTotalConstraint(_ normalized: String) -> Bool {
        guard normalized.contains("total") || normalized.contains("across") else { return false }
        let mediaTypeCount = ["image", "video", "audio"].filter {
            normalized.contains($0)
        }.count
        return mediaTypeCount > 1 || normalized.contains("+")
    }

    private static func framesCountTowardImageReferenceLimit(_ model: ModelItem) -> Bool {
        (model.constraints ?? []).contains { value in
            let normalized = value.lowercased().replacingOccurrences(of: "_", with: " ")
            return normalized.contains("image")
                && normalized.contains("reference")
                && !isAggregateTotalConstraint(normalized)
                && (normalized.contains("counting") || normalized.contains("including"))
                && (normalized.contains("start image") || normalized.contains("end image"))
        }
    }

    private static func framesCountTowardTotalReferenceLimit(_ model: ModelItem) -> Bool {
        framesCountTowardImageReferenceLimit(model) || (model.constraints ?? []).contains { value in
            let normalized = value.lowercased().replacingOccurrences(of: "_", with: " ")
            return isAggregateTotalConstraint(normalized)
                && (normalized.contains("start image") || normalized.contains("end image"))
        }
    }

    private static func maxOutputImages(
        _ model: ModelItem,
        capabilityProfile: ResolvedCapabilityProfileV1?
    ) -> Int {
        let names = Set(["batch_size", "num_images", "number_of_images"])
        let parameters = model.parameters?
            .filter { names.contains(($0.name ?? "").lowercased()) } ?? []
        guard !parameters.isEmpty else { return 1 }
        let declared = parameters.flatMap { parameter -> [Int] in
            var values = (parameter.options ?? []).compactMap { Int($0.text) }
            if let maximum = parameter.max { values.append(maximum) }
            return values
        }.max()
        let intrinsic = integerCapability(
            capabilityProfile,
            field: CapabilityFieldIDV1.imageOutputsPerRequest
        )
        return Swift.max(
            1,
            declared.map { declaredMaximum in
                intrinsic.map { Swift.min(declaredMaximum, $0) } ?? declaredMaximum
            }
                ?? intrinsic
                ?? 1
        )
    }

    private static func integerCapability(
        _ profile: ResolvedCapabilityProfileV1?,
        field: String
    ) -> Int? {
        guard let value = profile?.fields.integers[field]?.value, value >= 0 else {
            return nil
        }
        return value
    }

    private static func generationSchemaSupports(
        model: ModelItem,
        modality: Modality,
        schema: Value,
        modelParam: String?,
        includeMedia: Bool
    ) -> Bool {
        let roles = includeMedia ? Array(mediaRoles(model)).sorted() : []
        let params: BackendGenerationParams
        switch modality {
        case .image:
            params = .image(ImageGenerationParams(
                prompt: "schema preflight", aspectRatio: aspectRatios(model).first ?? "1:1",
                resolution: options(model, param: "resolution")?.first,
                quality: options(model, param: "quality")?.first,
                imageURLs: includeMedia && hasImageMedia(model)
                    ? ["https://example.invalid/reference.jpg"] : [],
                numImages: 1
            ))
        case .video:
            let declared = includeMedia ? mediaRoles(model) : []
            params = .video(VideoGenerationParams(
                prompt: "schema preflight",
                duration: .seconds(model.durations?.first ?? model.durationRange?.min ?? 5),
                aspectRatio: aspectRatios(model).first ?? "16:9",
                resolution: options(model, param: "resolution")?.first,
                startFrameURL: declared.contains("start_image")
                    ? "https://example.invalid/start.jpg" : nil,
                endFrameURL: declared.contains("end_image")
                    ? "https://example.invalid/end.jpg" : nil,
                referenceImageURLs: declared.contains("image") || declared.contains("image_references")
                    ? ["https://example.invalid/reference.jpg"] : [],
                referenceVideoURLs: declared.contains("video") || declared.contains("video_references")
                    ? ["https://example.invalid/reference.mp4"] : [],
                referenceAudioURLs: declared.contains("audio") || declared.contains("audio_references")
                    ? ["https://example.invalid/reference.wav"] : []
            ))
        case .audio:
            params = .audio(AudioGenerationParams(
                prompt: "schema preflight", voice: nil, lyrics: nil,
                styleInstructions: nil, instrumental: false,
                durationSeconds: model.durations?.first,
                videoURL: includeMedia && hasMedia(model, type: "video")
                    ? "https://example.invalid/reference.mp4" : nil
            ))
        case .upscale:
            params = .upscale(UpscaleGenerationParams(
                sourceURL: "https://example.invalid/source.png", durationSeconds: 1
            ))
        }
        return (try? MCPGenerationArguments.make(
            for: params, model: modelParam, schema: schema, mediaRoles: roles
        )) != nil
    }
}
