import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Treatment Brainstorm contract", .serialized)
struct TreatmentBrainstormContractTests {
    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var fixtures: [Data] = []
        nonisolated(unsafe) private static var captured: [(URLRequest, Data?)] = []

        static func install(_ bodies: [String]) {
            lock.withLock {
                fixtures = bodies.map { Data($0.utf8) }
                captured = []
            }
        }

        static func requests() -> [(URLRequest, Data?)] {
            lock.withLock { captured }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = Self.body(of: request)
            let responseBody = Self.lock.withLock { () -> Data in
                Self.captured.append((request, body))
                return Self.fixtures.isEmpty
                    ? Data(#"{"error":"missing fixture"}"#.utf8)
                    : Self.fixtures.removeFirst()
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func body(of request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { return nil }
                if count == 0 { return data }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("provider output is a closed nonempty schema")
    func closedProviderOutput() throws {
        let valid = try TreatmentBrainstormHTTPClient.parsed(
            "{\"title\":\"A\",\"summary\":\"B\",\"body_markdown\":\"C\"}",
            responseID: "r1",
            inputTokens: 1,
            outputTokens: 2
        )
        #expect(valid.output.bodyMarkdown == "C")
        #expect(throws: TreatmentBrainstormClientError.self) {
            _ = try TreatmentBrainstormHTTPClient.parsed(
                "{\"title\":\"A\",\"summary\":\"B\",\"body_markdown\":\"C\",\"origin\":\"openai\"}",
                responseID: nil,
                inputTokens: nil,
                outputTokens: nil
            )
        }
    }

    @Test("all provider clients request strict structured output and parse usage")
    func providerTransports() async throws {
        let output = #"{\"title\":\"A\",\"summary\":\"B\",\"body_markdown\":\"C\"}"#
        FixtureURLProtocol.install([
            "{\"id\":\"anthropic-1\",\"content\":[{\"type\":\"text\",\"text\":\"\(output)\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}",
            "{\"id\":\"openai-1\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"\(output)\"}]}],\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}",
            "{\"responseId\":\"google-1\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\(output)\"}]}}],\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":6}}",
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = TreatmentBrainstormHTTPClient(session: testSession)
        var responses: [TreatmentBrainstormProviderResponse] = []
        for provider in TreatmentBrainstormProvider.allCases {
            let model = try #require(TreatmentBrainstormModelCatalog.all.first { $0.provider == provider })
            responses.append(try await client.generate(
                .init(model: model, system: "system", input: "input"),
                apiKey: "secret"
            ))
        }
        #expect(responses.map(\.responseID) == ["anthropic-1", "openai-1", "google-1"])
        #expect(responses.map(\.inputTokens) == [1, 3, 5])
        let requests = FixtureURLProtocol.requests()
        #expect(requests.map { $0.0.url?.path } == ["/v1/messages", "/v1/responses", "/v1beta/models/gemini-3.8-flash:generateContent"])
        let requestObjects = try requests.map { request in
            try #require(JSONSerialization.jsonObject(with: try #require(request.1)) as? [String: Any])
        }
        #expect((requestObjects[0]["output_config"] as? [String: Any]) != nil)
        #expect((requestObjects[1]["text"] as? [String: Any]) != nil)
        #expect((requestObjects[2]["generationConfig"] as? [String: Any])?["responseMimeType"] as? String == "application/json")
    }

    @Test("model discovery is free, authenticated, and filters Google to executable text models")
    func modelDiscovery() async throws {
        FixtureURLProtocol.install([
            #"{"data":[{"id":"claude-sonnet-5"}]}"#,
            #"{"data":[{"id":"gpt-5.6-sol"}]}"#,
            #"{"models":[{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-only","supportedGenerationMethods":["embedContent"]}]}"#,
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = TreatmentBrainstormHTTPClient(session: testSession)
        let anthropic = try await client.offeredModelIDs(provider: .anthropic, apiKey: "a")
        let openAI = try await client.offeredModelIDs(provider: .openai, apiKey: "o")
        let google = try await client.offeredModelIDs(provider: .google, apiKey: "g")
        #expect(anthropic == ["claude-sonnet-5"])
        #expect(openAI == ["gpt-5.6-sol"])
        #expect(google == ["gemini-3.8-flash"])
        let requests = FixtureURLProtocol.requests().map(\.0)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests[0].value(forHTTPHeaderField: "x-api-key") == "a")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer o")
        #expect(requests[2].value(forHTTPHeaderField: "x-goog-api-key") == "g")
    }

    @Test("tool accepts no raw prompt or caller-supplied provenance")
    func toolSchemaIsHostOwned() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .brainstormTreatment })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["project_dir", "include_synthesis", "authorization_id"])
        #expect(tool.description.contains("Pass no prompt"))
        #expect(tool.description.contains("provider-billed call plan"))
    }

    @Test("model activation defaults off and persists only known model ids")
    func modelPreferences() throws {
        let suite = "TreatmentBrainstormContractTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try #require(TreatmentBrainstormModelCatalog.all.first)
        #expect(!TreatmentBrainstormPreferences.isEnabled(model, defaults: defaults))
        TreatmentBrainstormPreferences.setEnabled(true, model: model, defaults: defaults)
        defaults.set([model.preferenceID, "unknown:model"], forKey: TreatmentBrainstormPreferences.defaultsKey)
        #expect(TreatmentBrainstormPreferences.enabledRouteIDs(defaults: defaults) == Set([model.preferenceID]))
    }

    @Test("approval creates one exact expiring authorization and decline creates none")
    @MainActor
    func oneTimeAuthorization() throws {
        let service = AgentService(refreshBackendStatusOnInit: false)
        let dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let model = try #require(TreatmentBrainstormModelCatalog.all.first)
        let inputs = [TreatmentBrainstormInputProofV1(path: "brief.yaml", sha256: String(repeating: "a", count: 64))]
        let package = TreatmentBrainstormPromptPackage(
            inputs: inputs,
            idea: .init(system: "system", input: "input")
        )
        let plan = TreatmentBrainstormPlan(
            id: UUID().uuidString,
            dataRootPath: dataRoot.standardizedFileURL.path,
            models: [model, model],
            synthesisModel: nil,
            package: package
        )
        let dialog = AgentDialog(
            id: "approval",
            title: "Approve",
            symbol: "checkmark",
            intro: nil,
            costHint: "2 calls",
            confirmLabel: "Continue",
            textField: nil,
            sections: [],
            workflowDecision: .treatmentBrainstormApproval
        )
        service.treatmentBrainstormState.pendingApprovals[dialog.id] = .init(
            plan: plan,
            projectID: ""
        )
        let context = try service.resolveTreatmentBrainstormApproval(dialog, selected: ["approve"])
        #expect(context.contains("authorized once"))
        let authorizationID = try #require(service.treatmentBrainstormState.authorizations.keys.first)
        let editor = ToolHarness().editor
        _ = try service.claimTreatmentBrainstormAuthorization(
            authorizationID,
            editor: editor,
            package: package,
            dataRoot: dataRoot,
            includeSynthesis: false
        )
        #expect(throws: ToolError.self) {
            _ = try service.claimTreatmentBrainstormAuthorization(
                authorizationID,
                editor: editor,
                package: package,
                dataRoot: dataRoot,
                includeSynthesis: false
            )
        }

        service.treatmentBrainstormState.pendingApprovals[dialog.id] = .init(
            plan: plan,
            projectID: ""
        )
        _ = try service.resolveTreatmentBrainstormApproval(dialog, selected: ["decline"])
        #expect(service.treatmentBrainstormState.authorizations.isEmpty)
    }

    @Test("cockpit exposes exact provider and model provenance")
    func cockpitProvenance() throws {
        let data = Data("""
        {
          "meta":{"version":3,"origin":"brainstorm_openai"},
          "body_markdown":"Body",
          "brainstorm_provenance":{
            "relationship":"exact",
            "sources":[{
              "role":"idea",
              "provider_id":"openai",
              "model_id":"gpt-fixture",
              "variant_id":"v",
              "response_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }]
          }
        }
        """.utf8)
        let treatment = try JSONDecoder().decode(TreatmentData.self, from: data)
        #expect(treatment.origin == "brainstorm_openai")
        #expect(treatment.brainstormProvenance?.sources.first?.providerID == "openai")
        #expect(treatment.brainstormProvenance?.sources.first?.modelID == "gpt-fixture")
    }
}
