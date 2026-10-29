import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Production frame boundary authority")
struct ProductionFrameBindingTests {
    @Test("An identical prompt cannot reuse a start-frame token for the end frame")
    func boundaryRemainsPartOfAuthority() throws {
        let start = PromptBinding(projectKey: "project", shotId: "shot", shotFingerprint: "plan", frameRole: "start")
        let end = PromptBinding(projectKey: "project", shotId: "shot", shotFingerprint: "plan", frameRole: "end")
        let text = "A still figure in a fixed room."
        let token = PromptCompiler.token(for: text, modelId: "image-model", binding: start)
        #expect(PromptCompiler.validate(token: token, text: text, modelId: "image-model", binding: start))
        #expect(!PromptCompiler.validate(token: token, text: text, modelId: "image-model", binding: end))
        #expect(!start.matchesCurrentState(of: end))
        #expect(!start.withPromptIRSHA256("image-ir").matchesCurrentState(of: end.withPromptIRSHA256("image-ir")))
        let restored = try JSONDecoder().decode(PromptBinding.self, from: JSONEncoder().encode(end))
        #expect(restored == end)
    }
}
