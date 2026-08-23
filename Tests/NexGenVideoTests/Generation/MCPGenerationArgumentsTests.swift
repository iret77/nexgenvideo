import Testing
import MCP

@testable import NexGenVideo

@Suite("MCP generation argument mapping")
struct MCPGenerationArgumentsTests {
    @Test func higgsfieldNestedParamsReceiveCompiledRequest() throws {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "params": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "model": .object(["type": .string("string")]),
                        "prompt": .object(["type": .string("string")]),
                        "aspect_ratio": .object(["type": .string("string")]),
                        "num_images": .object(["type": .string("integer")]),
                    ]),
                    "required": .array([.string("model"), .string("prompt")]),
                ]),
            ]),
            "required": .array([.string("params")]),
        ])
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled lighting anchor",
            aspectRatio: "9:16",
            resolution: nil,
            quality: nil,
            imageURLs: [],
            numImages: 1
        ))

        let arguments = try MCPGenerationArguments.make(
            for: params,
            model: "nano_banana_pro",
            schema: schema
        )

        guard case .object(let nested)? = arguments["params"] else {
            Issue.record("Expected nested params object")
            return
        }
        #expect(arguments["prompt"] == nil)
        #expect(nested["model"] == .string("nano_banana_pro"))
        #expect(nested["prompt"] == .string("compiled lighting anchor"))
        #expect(nested["aspect_ratio"] == .string("9:16"))
        #expect(nested["num_images"] == .int(1))
    }

    @Test func topLevelSchemaKeepsTopLevelArguments() throws {
        let schema: Value = .object([
            "properties": .object([
                "model": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("model"), .string("prompt")]),
        ])
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled prompt",
            aspectRatio: "1:1",
            resolution: nil,
            quality: nil,
            imageURLs: [],
            numImages: 1
        ))

        let arguments = try MCPGenerationArguments.make(
            for: params,
            model: "image-model",
            schema: schema
        )

        #expect(arguments["model"] == .string("image-model"))
        #expect(arguments["prompt"] == .string("compiled prompt"))
    }

    @Test func rootSchemaAlternativesChooseTheCompleteMediaContract() throws {
        let textOnly: Value = .object([
            "properties": .object([
                "model": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("model"), .string("prompt")]),
        ])
        let withMedia: Value = .object([
            "properties": .object([
                "model": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
                "image_urls": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ]),
            ]),
            "required": .array([.string("model"), .string("prompt"), .string("image_urls")]),
        ])
        let schema: Value = .object(["oneOf": .array([textOnly, withMedia])])
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled prompt",
            aspectRatio: "1:1",
            resolution: nil,
            quality: nil,
            imageURLs: ["media-1"],
            numImages: 1
        ))

        let arguments = try MCPGenerationArguments.make(
            for: params, model: "image-model", schema: schema
        )

        #expect(arguments["image_urls"] == .array([.string("media-1")]))
    }

    @Test func higgsfieldMediasPreserveEveryReferenceAndDeclaredRole() throws {
        let schema: Value = .object([
            "properties": .object([
                "params": .object([
                    "properties": .object([
                        "model": .object(["type": .string("string")]),
                        "prompt": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("model"), .string("prompt")]),
                ]),
                "medias": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "value": .object(["type": .string("string")]),
                            "role": .object([
                                "type": .string("string"),
                                "enum": .array([.string("image_references")]),
                            ]),
                        ]),
                        "required": .array([.string("value"), .string("role")]),
                    ]),
                ]),
            ]),
            "required": .array([.string("params"), .string("medias")]),
        ])
        let references = ["media-1", "media-2", "media-3", "media-4"]
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled lighting anchor",
            aspectRatio: "9:16",
            resolution: nil,
            quality: nil,
            imageURLs: references,
            numImages: 1
        ))

        let arguments = try MCPGenerationArguments.make(
            for: params,
            model: "nano_banana_pro",
            schema: schema,
            mediaRoles: ["image_references"]
        )

        guard case .array(let medias)? = arguments["medias"] else {
            Issue.record("Expected medias array")
            return
        }
        #expect(medias.count == 4)
        for (index, media) in medias.enumerated() {
            #expect(media == .object([
                "value": .string(references[index]),
                "role": .string("image_references"),
            ]))
        }
    }

    @Test func optionalReferencesCannotBeSilentlyDropped() {
        let schema: Value = .object([
            "properties": .object([
                "model": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("model"), .string("prompt")]),
        ])
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled prompt",
            aspectRatio: "1:1",
            resolution: nil,
            quality: nil,
            imageURLs: ["media-1"],
            numImages: 1
        ))

        #expect(throws: MCPGenerationArguments.MappingError.unsupportedMediaRoles(["image"])) {
            try MCPGenerationArguments.make(for: params, model: "image-model", schema: schema)
        }
    }

    @Test func singularReferenceFieldRejectsMultipleInputs() {
        let schema: Value = .object([
            "properties": .object([
                "model": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
                "reference_image": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("model"), .string("prompt")]),
        ])
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled prompt",
            aspectRatio: "1:1",
            resolution: nil,
            quality: nil,
            imageURLs: ["media-1", "media-2"],
            numImages: 1
        ))

        #expect(throws: MCPGenerationArguments.MappingError.tooManyMedia(
            field: "reference_image", count: 2
        )) {
            try MCPGenerationArguments.make(for: params, model: "image-model", schema: schema)
        }
    }

    @Test func dedicatedFrameFieldMapsBeforeAggregateMedia() throws {
        let schema: Value = .object([
            "properties": .object([
                "model": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
                "start_image": .object(["type": .string("string")]),
                "medias": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "value": .object(["type": .string("string")]),
                            "role": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("value"), .string("role")]),
                    ]),
                ]),
            ]),
            "required": .array([.string("model"), .string("prompt")]),
        ])
        let params = BackendGenerationParams.video(VideoGenerationParams(
            prompt: "compiled prompt",
            duration: 5,
            aspectRatio: "16:9",
            resolution: nil,
            startFrameURL: "start-media",
            referenceImageURLs: ["reference-media"]
        ))

        let arguments = try MCPGenerationArguments.make(
            for: params,
            model: "video-model",
            schema: schema,
            mediaRoles: ["start_image", "image"]
        )

        #expect(arguments["start_image"] == .string("start-media"))
        #expect(arguments["medias"] == .array([
            .object(["value": .string("reference-media"), "role": .string("image")]),
        ]))
    }

    @Test func singularAggregateMediaUsesItsObjectSchema() throws {
        let schema: Value = .object([
            "properties": .object([
                "model": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
                "media": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string")]),
                        "role": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("id"), .string("role")]),
                ]),
            ]),
            "required": .array([.string("model"), .string("prompt"), .string("media")]),
        ])
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled prompt",
            aspectRatio: "1:1",
            resolution: nil,
            quality: nil,
            imageURLs: ["media-1"],
            numImages: 1
        ))

        let arguments = try MCPGenerationArguments.make(
            for: params, model: "image-model", schema: schema
        )

        #expect(arguments["media"] == .object([
            "id": .string("media-1"),
            "role": .string("image"),
        ]))
    }

    @Test func jobToolsAcceptNestedPluralIdentifiers() throws {
        let schema: Value = .object([
            "properties": .object([
                "params": .object([
                    "properties": .object([
                        "job_ids": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                        ]),
                        "sync": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("job_ids")]),
                ]),
            ]),
            "required": .array([.string("params")]),
        ])

        let arguments = try MCPGenerationArguments.makeJob(
            jobID: "job-123", schema: schema, sync: true
        )

        #expect(arguments == [
            "params": .object([
                "job_ids": .array([.string("job-123")]),
                "sync": .bool(true),
            ]),
        ])
    }

    @Test func requiredSchemaDefaultsAreHonored() throws {
        let schema: Value = .object([
            "properties": .object([
                "model": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
                "output_format": .object([
                    "type": .string("string"),
                    "default": .string("png"),
                ]),
            ]),
            "required": .array([.string("model"), .string("prompt"), .string("output_format")]),
        ])
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled prompt",
            aspectRatio: "1:1",
            resolution: nil,
            quality: nil,
            imageURLs: [],
            numImages: 1
        ))

        let arguments = try MCPGenerationArguments.make(
            for: params, model: "image-model", schema: schema
        )

        #expect(arguments["output_format"] == .string("png"))
    }

    @Test func optionalDefaultsRemainProviderOwned() throws {
        let schema: Value = .object([
            "properties": .object([
                "model": .object(["type": .string("string")]),
                "prompt": .object(["type": .string("string")]),
                "source": .object([
                    "type": .string("string"),
                    "const": .string("widget"),
                ]),
                "billing_mode": .object([
                    "type": .string("string"),
                    "default": .string("provider-default"),
                ]),
            ]),
            "required": .array([.string("model"), .string("prompt")]),
        ])
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled prompt",
            aspectRatio: "1:1",
            resolution: nil,
            quality: nil,
            imageURLs: [],
            numImages: 1
        ))

        let arguments = try MCPGenerationArguments.make(
            for: params, model: "image-model", schema: schema
        )

        #expect(arguments["source"] == nil)
        #expect(arguments["billing_mode"] == nil)
    }

    @Test func requiredNestedPromptWinsOverOptionalAlias() throws {
        let schema: Value = .object([
            "properties": .object([
                "description": .object(["type": .string("string")]),
                "params": .object([
                    "properties": .object([
                        "model": .object(["type": .string("string")]),
                        "prompt": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("model"), .string("prompt")]),
                ]),
            ]),
            "required": .array([.string("params")]),
        ])
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled prompt",
            aspectRatio: "1:1",
            resolution: nil,
            quality: nil,
            imageURLs: [],
            numImages: 1
        ))

        let arguments = try MCPGenerationArguments.make(
            for: params, model: "image-model", schema: schema
        )

        #expect(arguments["description"] == nil)
        #expect(arguments["params"] == .object([
            "model": .string("image-model"),
            "prompt": .string("compiled prompt"),
        ]))
    }

    @Test func unsupportedRequiredFieldsFailBeforeSubmission() {
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
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled prompt",
            aspectRatio: "1:1",
            resolution: nil,
            quality: nil,
            imageURLs: [],
            numImages: 1
        ))

        #expect(throws: MCPGenerationArguments.MappingError.unsupportedRequiredFields([
            "params.workspace_id",
        ])) {
            try MCPGenerationArguments.make(
                for: params,
                model: "image-model",
                schema: schema
            )
        }
    }

    @Test func providerToolErrorPreservesItsMessage() {
        let error = MCPProviderClient.ClientError.toolFailed("Invalid params: prompt is required")
        #expect(error.localizedDescription == "Invalid params: prompt is required")
    }
}
