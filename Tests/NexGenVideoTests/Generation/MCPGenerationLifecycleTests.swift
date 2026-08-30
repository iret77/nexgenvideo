import Foundation
import MCP
import Testing

@testable import NexGenVideo

@Suite("MCP generation lifecycle")
struct MCPGenerationLifecycleTests {
    private func output(_ urls: [String]) -> MCPGenerationLifecycle.Output {
        MCPGenerationLifecycle.Output(urls: urls, inlineMedia: [])
    }

    private func tool(_ name: String, _ description: String? = nil) -> MCPProviderClient.DiscoveredTool {
        MCPProviderClient.DiscoveredTool(
            name: name,
            description: description,
            inputSchema: .object([:])
        )
    }

    @Test func submissionReadsAsynchronousJobWithoutMistakingItForOutput() {
        let submission = MCPGenerationLifecycle.submission(from: [
            #"{"job_id":"job-123","status":"queued"}"#,
        ])

        #expect(submission.jobID == "job-123")
        #expect(submission.outputURLs.isEmpty)
    }

    @Test func nestedJobIdentifierIsUsedWhenEnvelopeHasNoJobID() {
        let submission = MCPGenerationLifecycle.submission(from: [
            #"{"request_id":"request-1","jobs":[{"id":"job-456","status":"queued"}]}"#,
        ])

        #expect(submission.jobID == "job-456")
    }

    @Test func higgsfieldJobSetEnvelopeAndResultAreParsed() {
        let submission = MCPGenerationLifecycle.submission(from: [
            #"{"job_set_id":"set-123","status":"queued"}"#,
        ])
        let status = MCPGenerationLifecycle.status(from: [
            #"{"job_set":{"id":"set-123","status":"completed","jobs":[{"results":{"raw":{"url":"https://output.invalid/higgsfield.png"}}}]}}"#,
        ])

        #expect(submission.jobID == "set-123")
        #expect(status == .succeeded(output(["https://output.invalid/higgsfield.png"])))
    }

    @Test func topLevelGenericIdentifierIsAcceptedAsJobID() {
        let submission = MCPGenerationLifecycle.submission(from: [
            #"{"id":"job-789","status":"pending"}"#,
        ])

        #expect(submission.jobID == "job-789")
    }

    @Test func nestedJobIdentifierWinsOverEnvelopeIdentifier() {
        let submission = MCPGenerationLifecycle.submission(from: [
            #"{"id":"batch-1","jobs":[{"id":"job-456","status":"queued"}]}"#,
        ])

        #expect(submission.jobID == "job-456")
    }

    @Test func completedStatusReturnsOnlyOutputMedia() {
        let status = MCPGenerationLifecycle.status(from: [
            #"{"status":"completed","medias":[{"type":"media_input","url":"https://input.invalid/ref.jpg"}],"results":{"raw":{"url":"https://output.invalid/result.png"}}}"#,
        ])

        #expect(status == .succeeded(output(["https://output.invalid/result.png"])))
    }

    @Test func completedStatusNeverPromotesInputMediaToOutput() {
        let status = MCPGenerationLifecycle.status(from: [
            #"{"status":"completed","medias":[{"type":"media_input","url":"https://input.invalid/ref.jpg"}]}"#,
        ])

        #expect(status == .succeeded(output([])))
    }

    @Test func outputParsingRejectsThumbnailShareAndProseLinks() {
        let structured = MCPGenerationLifecycle.submission(from: [
            #"{"result":{"rawUrl":"https://output.invalid/final.png","outputUrl":"https://output.invalid/proxy.png","thumbnail_url":"https://output.invalid/thumb.jpg","share_url":"https://provider.invalid/jobs/1"}}"#,
        ])
        let prose = MCPGenerationLifecycle.submission(from: [
            "Job accepted. Follow it at https://provider.invalid/jobs/1",
        ])

        #expect(structured.outputURLs == ["https://output.invalid/final.png"])
        #expect(prose.outputURLs.isEmpty)
    }

    @Test func outputArrayOrderIsPreserved() {
        let submission = MCPGenerationLifecycle.submission(from: [
            #"{"results":[{"url":"https://output.invalid/1.png"},{"url":"https://output.invalid/2.png"}]}"#,
        ])

        #expect(submission.outputURLs == [
            "https://output.invalid/1.png",
            "https://output.invalid/2.png",
        ])
    }

    @Test func completedOrResultToolMayReturnOneRootMediaURL() {
        #expect(MCPGenerationLifecycle.status(from: [
            #"{"status":"completed","url":"https://output.invalid/final.png"}"#,
        ]) == .succeeded(output(["https://output.invalid/final.png"])))
        #expect(MCPGenerationLifecycle.resultURLs(from: [
            #"{"url":"https://output.invalid/final.png"}"#,
        ]) == ["https://output.invalid/final.png"])
    }

    @Test func failedStatusPreservesProviderMessage() {
        let status = MCPGenerationLifecycle.status(from: [
            #"{"state":"failed","error_message":"Model rejected the selected duration."}"#,
        ])

        #expect(status == .failed("Model rejected the selected duration."))
    }

    @Test func richMCPImageContentSurvivesIntoGenerationOutput() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let result = CallTool.Result(content: [
            .image(
                data: bytes.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil
            ),
        ])

        let submission = MCPGenerationLifecycle.submission(
            from: MCPProviderClient.payloadContents(result)
        )

        #expect(submission.output.urls.isEmpty)
        #expect(submission.output.inlineMedia == [
            MCPGenerationLifecycle.InlineMedia(data: bytes, mimeType: "image/png"),
        ])
    }

    @Test func mixedRichContentKeepsProviderOrderAndDropsExactDuplicates() {
        let first = Data([0x01, 0x02])
        let second = Data([0x03, 0x04])
        let result = CallTool.Result(content: [
            .image(
                data: first.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil
            ),
            .text(
                text: #"{"result":{"url":"https://output.invalid/second.png"}}"#,
                annotations: nil,
                _meta: nil
            ),
            .image(
                data: first.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil
            ),
            .image(
                data: second.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil
            ),
        ])

        let output = MCPGenerationLifecycle.submission(
            from: MCPProviderClient.payloadContents(result)
        ).output

        #expect(output.media == [
            .inline(.init(data: first, mimeType: "image/png")),
            .remoteURL("https://output.invalid/second.png"),
            .inline(.init(data: second, mimeType: "image/png")),
        ])
    }

    @Test func structuredMixedMediaKeepsArrayOrder() {
        let inline = Data([0x05, 0x06])
        let result = CallTool.Result(
            content: [],
            structuredContent: .object([
                "results": .array([
                    .object(["url": .string("https://output.invalid/first.png")]),
                    .object([
                        "data": .string(inline.base64EncodedString()),
                        "mime_type": .string("image/png"),
                    ]),
                    .object(["url": .string("https://output.invalid/third.png")]),
                ]),
            ])
        )

        let output = MCPGenerationLifecycle.submission(
            from: MCPProviderClient.payloadContents(result)
        ).output

        #expect(output.media == [
            .remoteURL("https://output.invalid/first.png"),
            .inline(.init(data: inline, mimeType: "image/png")),
            .remoteURL("https://output.invalid/third.png"),
        ])
    }

    @Test func echoedInputMediaIsNeverPromotedToInlineOutput() {
        let encoded = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let submission = MCPGenerationLifecycle.submission(from: [
            #"{"type":"media_input","_ngv_inline_media":{"data":"\#(encoded)","mime_type":"image/png"}}"#,
        ])

        #expect(submission.output.inlineMedia.isEmpty)
    }

    @Test func structuredInputBytesAreExcludedButResultBytesSurvive() throws {
        let input = Data([0x01, 0x02]).base64EncodedString()
        let output = Data([0x03, 0x04]).base64EncodedString()
        let object: [String: Any] = [
            "job_id": "job-1",
            "status": "queued",
            "result": [
                "input_image": ["data": input, "mimeType": "image/png"],
                "request_payload": ["blob": input, "content_type": "image/png"],
                "image": ["data": output, "mimeType": "image/png"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        var remaining = MCPGenerationLifecycle.maxInlineMediaBase64Characters

        let extraction = MCPProviderClient.inlineMediaPayloads(
            in: data,
            remainingCharacters: &remaining
        )
        let payloads = [extraction.sanitizedPayload].compactMap { $0 }
        let submission = MCPGenerationLifecycle.submission(from: payloads)

        #expect(extraction.foundCandidate)
        #expect(extraction.sanitizedPayload?.contains(input) == false)
        #expect(submission.jobID == "job-1")
        #expect(MCPGenerationLifecycle.status(from: payloads) == .pending)
        #expect(submission.output.inlineMedia == [
            MCPGenerationLifecycle.InlineMedia(data: Data([0x03, 0x04]), mimeType: "image/png"),
        ])
    }

    @MainActor
    @Test func inlineMediaContainerMustMatchDeclaredMIMEType() {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let truncatedPNG = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D,
        ])
        let truncatedWAV = Data([
            0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45,
        ])

        #expect(GenerationService.validatedFileExtension(
            data: png, mimeType: "image/png", expectedType: .image
        ) == "png")
        #expect(GenerationService.validatedFileExtension(
            data: truncatedPNG, mimeType: "image/png", expectedType: .image
        ) == nil)
        #expect(GenerationService.validatedFileExtension(
            data: png, mimeType: "image/jpeg", expectedType: .image
        ) == nil)
        #expect(GenerationService.validatedFileExtension(
            data: truncatedWAV, mimeType: "audio/wav", expectedType: .audio
        ) == nil)
    }

    @Test func outputSchemaRecognizesStructuredMediaURLs() {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "images": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "url": .object(["type": .string("string")]),
                        ]),
                    ]),
                ]),
            ]),
        ])

        #expect(MCPGenerationLifecycle.outputSchemaSupportsMedia(schema))
    }

    @Test func unknownStatusPreservesProviderValue() {
        let status = MCPGenerationLifecycle.status(from: [
            #"{"status":"provider-specific-starting"}"#,
        ])

        #expect(status == .unknown("provider-specific-starting"))
    }

    @Test func lifecycleToolSelectionNeverChoosesGenerateAgain() {
        let tools = [
            tool("generate_image", "Generate an image and report status."),
            tool("job_status", "Check generation job status."),
            tool("job_display", "Display generation job output."),
            tool("job_cancel", "Cancel a generation job."),
        ]

        #expect(MCPGenerationLifecycle.statusTool(in: tools)?.name == "job_status")
        #expect(MCPGenerationLifecycle.resultTool(in: tools)?.name == "job_display")
        #expect(MCPGenerationLifecycle.cancelTool(in: tools)?.name == "job_cancel")
    }
}
