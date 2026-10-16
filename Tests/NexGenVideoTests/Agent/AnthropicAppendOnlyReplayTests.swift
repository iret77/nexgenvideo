import Foundation
import Testing
@testable import NexGenVideo

@Suite("Anthropic append-only replay")
@MainActor
struct AnthropicAppendOnlyReplayTests {
    private let image = AgentRuntimeImage(mediaType: "image/png", base64: "aW1hZ2U=")

    private func context(phase: String = "Write the story.") -> AgentRuntimeHostContext {
        AgentRuntimeHostContext(
            interfaceLanguage: .init(identifier: "en-GB", displayName: "English"),
            baseInstructions: "Host instructions",
            pack: .init(id: "musicvideo", version: "1.0.0", projectSchema: "1", currentPhase: "story"),
            phaseInstructions: phase,
            toolSchemas: [.init(name: "host_tool", description: "Tool", inputSchema: ["type": "object"])],
            authority: [.toolSchemas, .toolExecution]
        )
    }

    private func thinking(_ signature: String) throws -> AnthropicThinkingBlock {
        try AnthropicThinkingBlock(json: ["type": "thinking", "thinking": "", "signature": signature])
    }

    /// The digest the adapter records for a request carrying exactly this replayed history.
    private func digest(
        _ messages: [AgentRuntimeMessage],
        _ hostContext: AgentRuntimeHostContext
    ) -> String {
        AnthropicPrefixDigest.of(
            system: hostContext.systemInstructions,
            tools: hostContext.toolSchemas,
            messages: AnthropicReplay.wireMessages(messages)
        )
    }

    private func thinkingSignatures(_ replay: [AgentRuntimeMessage]) -> [String] {
        replay.flatMap(\.content).compactMap { content in
            guard case .thinking(let block) = content else { return nil }
            return block.json["signature"] as? String
        }
    }

    @Test("images sent with a turn stay in that turn on every later request and after reload")
    func attachedImagesPersist() async throws {
        let host = context()
        let first = AgentMessage(role: .user, blocks: [.text("Result")], hidden: true, attachedImages: [image])
        let restored = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(first))
        #expect(restored.attachedImages == [image])
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.messages = [
            restored,
            AgentMessage(role: .assistant, blocks: [.text("Seen.")]),
            AgentMessage(role: .user, blocks: [.text("Next")]),
        ]
        let replay = await service.runtimeMessages(hostContext: host)
        #expect(replay.count == 3)
        #expect(replay[0].content == [.text("Result"), .image(image)])
        let legacy = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data(#"{"id":"5F0C8A5E-2C55-4B6B-8E43-0B2E9A1F4C11","role":"user","blocks":[]}"#.utf8)
        )
        #expect(legacy.attachedImages.isEmpty)
        #expect(legacy.providerPrefixDigest == nil)
    }

    @Test("follow-up images already carried by a tool result are not attached a second time")
    func followUpImagesAreNotDuplicated() {
        let other = AgentRuntimeImage(mediaType: "image/jpeg", base64: "b3RoZXI=")
        let history = [AgentMessage(role: .user, blocks: [.toolResult(
            toolUseId: "spend",
            content: [.text("Done"), .image(base64: image.base64, mediaType: image.mediaType)],
            isError: false
        )])]
        #expect(AgentService.imagesMissingFromToolResults([image, other], in: history) == [other])
    }

    @Test("thinking from an unchanged prefix is replayed verbatim")
    func unchangedPrefixKeepsThinking() async throws {
        let host = context()
        let question = AgentMessage(role: .user, blocks: [.text("Plan it")])
        var answer = AgentMessage(role: .assistant, blocks: [.thinking(try thinking("one==")), .text("Planned.")])
        let service = AgentService(refreshBackendStatusOnInit: false)
        service.messages = [question]
        let answerPrefix = await service.runtimeMessages(hostContext: host)
        answer.providerPrefixDigest = digest(answerPrefix, host)
        service.messages = [question, answer, AgentMessage(role: .user, blocks: [.text("Continue")])]
        let replay = await service.runtimeMessages(hostContext: host)
        #expect(thinkingSignatures(replay) == ["one=="])
    }

    @Test("a changed system prompt drops earlier thinking as a leading run; later thinking stays")
    func systemChangeStripsLeadingRun() async throws {
        let story = context()
        let script = context(phase: "Write the script.")
        let service = AgentService(refreshBackendStatusOnInit: false)
        let u1 = AgentMessage(role: .user, blocks: [.text("Story")])
        service.messages = [u1]
        var a1 = AgentMessage(role: .assistant, blocks: [.thinking(try thinking("story==")), .text("Story done.")])
        let a1Prefix = await service.runtimeMessages(hostContext: story)
        a1.providerPrefixDigest = digest(a1Prefix, story)
        let u2 = AgentMessage(role: .user, blocks: [.text("Script")])
        service.messages = [u1, a1, u2]
        let afterTransition = await service.runtimeMessages(hostContext: script)
        #expect(thinkingSignatures(afterTransition).isEmpty)
        #expect(afterTransition[1].content == [.text("Story done.")])

        var a2 = AgentMessage(role: .assistant, blocks: [.thinking(try thinking("script==")), .text("Script done.")])
        a2.providerPrefixDigest = digest(afterTransition, script)
        service.messages = [u1, a1, u2, a2, AgentMessage(role: .user, blocks: [.text("Next")])]
        let later = await service.runtimeMessages(hostContext: script)
        #expect(thinkingSignatures(later) == ["script=="])
    }

    @Test("an assistant turn without a recorded prefix strips everything before it, never after")
    func legacyTurnBoundsTheStrip() async throws {
        let host = context()
        let service = AgentService(refreshBackendStatusOnInit: false)
        let u1 = AgentMessage(role: .user, blocks: [.text("One")])
        let a1 = AgentMessage(role: .assistant, blocks: [.thinking(try thinking("legacy==")), .text("One.")])
        let u2 = AgentMessage(role: .user, blocks: [.text("Two")])
        service.messages = [u1, a1, u2]
        let sent = await service.runtimeMessages(hostContext: host)
        var a2 = AgentMessage(role: .assistant, blocks: [.thinking(try thinking("fresh==")), .text("Two.")])
        a2.providerPrefixDigest = digest(sent, host)
        service.messages = [u1, a1, u2, a2, AgentMessage(role: .user, blocks: [.text("Three")])]
        let replay = await service.runtimeMessages(hostContext: host)
        #expect(thinkingSignatures(replay) == ["fresh=="])
    }

    @Test("an omitted incomplete response is never part of a prefix, so later thinking stays valid")
    func incompleteResponseOmissionIsStable() async throws {
        let host = context()
        let service = AgentService(refreshBackendStatusOnInit: false)
        let u1 = AgentMessage(role: .user, blocks: [.text("Draft")])
        var partial = AgentMessage(role: .assistant, blocks: [.thinking(try thinking("partial==")), .text("Half")])
        partial.isIncompleteAPIResponse = true
        let u2 = AgentMessage(role: .user, blocks: [.text("Again")])
        service.messages = [u1, partial, u2]
        let sent = await service.runtimeMessages(hostContext: host)
        #expect(sent.allSatisfy { $0.role == .user })
        var a2 = AgentMessage(role: .assistant, blocks: [.thinking(try thinking("retry==")), .text("Full")])
        a2.providerPrefixDigest = digest(sent, host)
        service.messages = [u1, partial, u2, a2, AgentMessage(role: .user, blocks: [.text("Thanks")])]
        let replay = await service.runtimeMessages(hostContext: host)
        #expect(thinkingSignatures(replay) == ["retry=="])
        #expect(!replay.flatMap(\.content).contains(.text("Half")))
    }

    @Test("an edited earlier user turn invalidates every later block")
    func editedTurnStripsLaterThinking() async throws {
        let host = context()
        let service = AgentService(refreshBackendStatusOnInit: false)
        let u1 = AgentMessage(role: .user, blocks: [.text("Result")], attachedImages: [image])
        service.messages = [u1]
        var a1 = AgentMessage(role: .assistant, blocks: [.thinking(try thinking("seen==")), .text("Seen.")])
        let a1Prefix = await service.runtimeMessages(hostContext: host)
        a1.providerPrefixDigest = digest(a1Prefix, host)
        var edited = u1
        edited.attachedImages = []
        service.messages = [edited, a1, AgentMessage(role: .user, blocks: [.text("Next")])]
        let replay = await service.runtimeMessages(hostContext: host)
        #expect(thinkingSignatures(replay).isEmpty)
    }

    @Test("a model switch replays thinking unchanged; the API decides which blocks it can read")
    func modelSwitchKeepsBlocks() async throws {
        let defaults = AnthropicModelFixtures.isolatedDefaults()
        let host = context()
        let service = AgentService(refreshBackendStatusOnInit: false, modelCatalogDefaults: defaults)
        let u1 = AgentMessage(role: .user, blocks: [.text("Plan")])
        service.messages = [u1]
        var a1 = AgentMessage(role: .assistant, blocks: [.thinking(try thinking("opus==")), .text("Planned.")])
        let a1Prefix = await service.runtimeMessages(hostContext: host)
        a1.providerPrefixDigest = digest(a1Prefix, host)
        service.messages = [u1, a1, AgentMessage(role: .user, blocks: [.text("Go on")])]
        service.selectModel(AnthropicModelFixtures.info(AnthropicModelFixtures.haiku45))
        let replay = await service.runtimeMessages(hostContext: host)
        #expect(thinkingSignatures(replay) == ["opus=="])
        let body = AnthropicRequestBody.build(
            model: AnthropicModelFixtures.info(AnthropicModelFixtures.haiku45),
            system: host.systemInstructions,
            tools: [],
            messages: AnthropicReplay.wireMessages(replay).map {
                AnthropicMessage(
                    role: $0.role == .user ? .user : .assistant,
                    content: $0.content.map(AnthropicRuntimeAdapter.anthropicContent)
                )
            }
        )
        let wire = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(wire[1]["content"] as? [[String: Any]])
        #expect(assistant.first?["signature"] as? String == "opus==")
    }

    @Test("consecutive same-role turns are joined on the wire, and the digest ignores the join")
    func wireJoinsSameRoleTurns() {
        let host = context()
        let split: [AgentRuntimeMessage] = [
            .init(role: .user, content: [.toolResult(id: "t1", content: [.text("one")], isError: false)]),
            .init(role: .user, content: [.text("Host generation result: done")]),
        ]
        let wire = AnthropicReplay.wireMessages(split)
        #expect(wire.count == 1)
        #expect(wire[0].content.count == 2)
        #expect(digest(split, host) == AnthropicPrefixDigest.of(
            system: host.systemInstructions, tools: host.toolSchemas, messages: split
        ))
    }
}
