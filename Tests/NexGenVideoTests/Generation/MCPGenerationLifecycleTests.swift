import Foundation
import MCP
import Testing

@testable import NexGenVideo

@Suite("MCP generation lifecycle")
struct MCPGenerationLifecycleTests {
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

        #expect(status == .succeeded(["https://output.invalid/result.png"]))
    }

    @Test func completedStatusNeverPromotesInputMediaToOutput() {
        let status = MCPGenerationLifecycle.status(from: [
            #"{"status":"completed","medias":[{"type":"media_input","url":"https://input.invalid/ref.jpg"}]}"#,
        ])

        #expect(status == .succeeded([]))
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

    @Test func failedStatusPreservesProviderMessage() {
        let status = MCPGenerationLifecycle.status(from: [
            #"{"state":"failed","error_message":"Model rejected the selected duration."}"#,
        ])

        #expect(status == .failed("Model rejected the selected duration."))
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
        ]

        #expect(MCPGenerationLifecycle.statusTool(in: tools)?.name == "job_status")
        #expect(MCPGenerationLifecycle.resultTool(in: tools)?.name == "job_display")
    }
}
