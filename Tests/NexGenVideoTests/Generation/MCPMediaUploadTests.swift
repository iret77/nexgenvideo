import Foundation
import MCP
import Testing

@testable import NexGenVideo

@Suite("MCP reference media upload")
struct MCPMediaUploadTests {
    actor UnusedClient: MCPToolCalling {
        func callTool(name: String, arguments: [String: Value]) async throws -> [String] {
            Issue.record("Unexpected MCP call to \(name)")
            return []
        }
    }

    actor UploadRecorder {
        private var files: [(String, String)] = []

        func upload(_ url: URL, mediaType: String) -> String {
            files.append((url.lastPathComponent, mediaType))
            return "uploaded-\(url.lastPathComponent)"
        }

        func recorded() -> [(String, String)] { files }
    }

    private func tool(_ name: String, _ description: String? = nil) -> MCPProviderClient.DiscoveredTool {
        MCPProviderClient.DiscoveredTool(
            name: name,
            description: description,
            inputSchema: .object([:])
        )
    }

    @Test func uploadAndConfirmToolsAreDiscoveredByContract() {
        let uploadSchema: Value = .object([
            "properties": .object([
                "filename": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("filename")]),
        ])
        let confirmSchema: Value = .object([
            "properties": .object([
                "media_id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("media_id")]),
        ])
        let tools = [
            tool("generate_image", "Generate an image."),
            MCPProviderClient.DiscoveredTool(
                name: "media_upload", description: "Create a media upload.",
                inputSchema: uploadSchema
            ),
            MCPProviderClient.DiscoveredTool(
                name: "media_confirm", description: "Confirm uploaded media.",
                inputSchema: confirmSchema
            ),
        ]

        #expect(MCPMediaUpload.uploadTool(in: tools)?.name == "media_upload")
        #expect(MCPMediaUpload.confirmTool(in: tools)?.name == "media_confirm")
        #expect(MCPMediaUpload.supportsUploadContract(tools))
    }

    @Test func incompatibleUploadSchemaFailsCatalogPreflight() {
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "media_upload",
                description: "Create a media upload.",
                inputSchema: .object([
                    "properties": .object([
                        "workspace_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("workspace_id")]),
                ])
            ),
            tool("media_confirm", "Confirm uploaded media."),
        ]

        #expect(!MCPMediaUpload.supportsUploadContract(tools))
    }

    @Test func structuredUploadTicketPreservesURLAndMediaID() throws {
        let ticket = try #require(MCPMediaUpload.ticket(from: [
            #"{"upload":{"upload_url":"https://storage.invalid/presigned","media_id":"pending-123"}}"#,
        ]))

        #expect(ticket.uploadURL.absoluteString == "https://storage.invalid/presigned")
        #expect(ticket.mediaID == "pending-123")
    }

    @Test func uploadMetadataMatchesTheDiscoveredSchema() throws {
        let schema: Value = .object([
            "properties": .object([
                "filename": .object(["type": .string("string")]),
                "media_type": .object([
                    "type": .string("string"),
                    "enum": .array([.string("image"), .string("video")]),
                ]),
                "content_type": .object(["type": .string("string")]),
                "size": .object(["type": .string("integer")]),
            ]),
            "required": .array([
                .string("filename"), .string("media_type"),
                .string("content_type"), .string("size"),
            ]),
        ])

        let arguments = try MCPGenerationArguments.makeMediaUpload(
            filename: "reference.jpg",
            mimeType: "image/jpeg",
            mediaType: "image",
            fileSize: 42,
            schema: schema
        )

        #expect(arguments["filename"] == .string("reference.jpg"))
        #expect(arguments["media_type"] == .string("image"))
        #expect(arguments["content_type"] == .string("image/jpeg"))
        #expect(arguments["size"] == .int(42))
    }

    @Test func malformedUploadTicketFailsClosed() {
        #expect(MCPMediaUpload.ticket(from: [#"{"media_id":"pending-123"}"#]) == nil)
        #expect(MCPMediaUpload.ticket(from: [#"{"upload_url":"file:///tmp/ref.jpg","media_id":"x"}"#]) == nil)
    }

    @Test func confirmationMayReplacePendingIdentifier() {
        let id = MCPMediaUpload.confirmedMediaID(
            from: [#"{"media":{"id":"media-final"}}"#],
            fallback: "pending-123"
        )

        #expect(id == "media-final")
    }

    @Test func preparePreservesEveryVideoReferenceSlotAndDeduplicatesFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.webm")
        let start = directory.appendingPathComponent("start.tiff")
        let end = directory.appendingPathComponent("end.png")
        let audio = directory.appendingPathComponent("guide.ogg")
        for url in [source, start, end, audio] { try Data([1]).write(to: url) }

        let uploadSchema: Value = .object([
            "properties": .object([
                "filename": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("filename")]),
        ])
        let confirmSchema: Value = .object([
            "properties": .object([
                "media_id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("media_id")]),
        ])
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "media_upload", description: nil, inputSchema: uploadSchema
            ),
            MCPProviderClient.DiscoveredTool(
                name: "media_confirm", description: nil, inputSchema: confirmSchema
            ),
        ]
        let params = BackendGenerationParams.video(VideoGenerationParams(
            prompt: "compiled prompt",
            duration: 5,
            aspectRatio: "16:9",
            resolution: nil,
            sourceVideoURL: source.path,
            startFrameURL: start.path,
            endFrameURL: end.path,
            referenceImageURLs: [start.path, end.path],
            referenceVideoURLs: [source.path],
            referenceAudioURLs: [audio.path]
        ))
        let recorder = UploadRecorder()

        let prepared = try await MCPMediaUpload.prepare(
            params,
            tools: tools,
            client: UnusedClient(),
            referenceUploader: { url, mediaType in
                await recorder.upload(url, mediaType: mediaType)
            }
        )
        guard case .video(let video) = prepared else {
            Issue.record("Expected video parameters")
            return
        }

        #expect(video.sourceVideoURL == "uploaded-source.webm")
        #expect(video.startFrameURL == "uploaded-start.tiff")
        #expect(video.endFrameURL == "uploaded-end.png")
        #expect(video.referenceImageURLs == ["uploaded-start.tiff", "uploaded-end.png"])
        #expect(video.referenceVideoURLs == ["uploaded-source.webm"])
        #expect(video.referenceAudioURLs == ["uploaded-guide.ogg"])
        let recorded = await recorder.recorded()
        #expect(recorded.count == 4)
        #expect(recorded.map { $0.1 } == ["video", "image", "image", "audio"])
    }

    @Test func prepareRejectsMissingFileBeforeAnyUpload() async {
        let uploadSchema: Value = .object([
            "properties": .object([
                "filename": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("filename")]),
        ])
        let confirmSchema: Value = .object([
            "properties": .object([
                "media_id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("media_id")]),
        ])
        let tools = [
            MCPProviderClient.DiscoveredTool(
                name: "media_upload", description: nil, inputSchema: uploadSchema
            ),
            MCPProviderClient.DiscoveredTool(
                name: "media_confirm", description: nil, inputSchema: confirmSchema
            ),
        ]
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let params = BackendGenerationParams.image(ImageGenerationParams(
            prompt: "compiled prompt",
            aspectRatio: "1:1",
            resolution: nil,
            quality: nil,
            imageURLs: [missing.path],
            numImages: 1
        ))

        await #expect(throws: MCPMediaUpload.UploadError.localFileMissing(missing.path)) {
            try await MCPMediaUpload.prepare(
                params,
                tools: tools,
                client: UnusedClient(),
                referenceUploader: { _, _ in
                    Issue.record("Missing file must not reach the uploader")
                    return "unexpected"
                }
            )
        }
    }
}
