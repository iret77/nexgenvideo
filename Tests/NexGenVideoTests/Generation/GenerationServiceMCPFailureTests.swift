import Foundation
import Testing

@testable import NexGenVideo

@Suite("GenerationService MCP failure classification")
struct GenerationServiceMCPFailureTests {
    private let providerName = "Higgsfield"
    private let toolName = "generate_video"
    private let modelName = "veo"

    @Test func cancellationBeforeDispatchUsesNativeCopyAndReleasesSpend() {
        let handling = GenerationService.classifyMCPFailure(
            CancellationError(),
            didDispatch: false,
            providerName: providerName,
            toolName: toolName,
            modelName: modelName
        )

        #expect(handling == .failBeforeSubmission("Generation cancelled."))
    }

    @Test func cancellationAfterDispatchUsesNativeCopyAndKeepsSubmittedSpend() {
        let handling = GenerationService.classifyMCPFailure(
            CancellationError(),
            didDispatch: true,
            providerName: providerName,
            toolName: toolName,
            modelName: modelName
        )

        #expect(handling == .failJob("Generation cancelled."))
    }

    @Test func mappingErrorKeepsItsPreSubmissionGuidance() {
        let handling = GenerationService.classifyMCPFailure(
            MCPGenerationArguments.MappingError.missingPrompt,
            didDispatch: false,
            providerName: providerName,
            toolName: toolName,
            modelName: modelName
        )

        #expect(handling == .failBeforeSubmission(
            "NexGenVideo cannot map Higgsfield MCP tool 'generate_video' for model 'veo': The generation tool has no usable prompt field. The generation request was not sent."
        ))
    }

    @Test func uploadErrorKeepsItsDispatchSensitiveGuidance() {
        let error = MCPMediaUpload.UploadError.toolsUnavailable

        #expect(GenerationService.classifyMCPFailure(
            error,
            didDispatch: false,
            providerName: providerName,
            toolName: toolName,
            modelName: modelName
        ) == .failBeforeSubmission(
            "Higgsfield reference upload failed before generation: The provider MCP cannot upload local reference media."
        ))
        #expect(GenerationService.classifyMCPFailure(
            error,
            didDispatch: true,
            providerName: providerName,
            toolName: toolName,
            modelName: modelName
        ) == .failJob(
            "Higgsfield MCP tool 'generate_video' for model 'veo' failed: The provider MCP cannot upload local reference media."
        ))
    }

    @Test func jobFailureKeepsItsProviderDiagnosticAfterDispatch() {
        let handling = GenerationService.classifyMCPFailure(
            MCPGenerationExecutor.JobFailure(jobID: "job-1", message: "provider rejected input"),
            didDispatch: true,
            providerName: providerName,
            toolName: toolName,
            modelName: modelName
        )

        #expect(handling == .failJob(
            "Higgsfield MCP tool 'generate_video' for model 'veo' failed: Provider job 'job-1' failed: provider rejected input"
        ))
    }
}
