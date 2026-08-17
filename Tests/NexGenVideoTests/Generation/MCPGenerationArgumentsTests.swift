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
