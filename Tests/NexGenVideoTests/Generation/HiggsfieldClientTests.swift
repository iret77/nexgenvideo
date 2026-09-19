import Foundation
import Testing
@testable import NexGenVideo

@Suite("Higgsfield REST transport", .serialized)
struct HiggsfieldClientTests {
    private static let id = "d7e6c0f3-6699-4f6c-bb45-2ad7fd9158ff"
    private static var receipt: HiggsfieldJobReceipt {
        .init(requestID: id, statusURL: URL(string: "https://api.higgsfield.ai/requests/\(id)/status")!,
              cancelURL: URL(string: "https://api.higgsfield.ai/requests/\(id)/cancel")!)
    }

    private final class Fixture: URLProtocol, @unchecked Sendable {
        struct Reply: Sendable {
            let status: Int
            let body: String
            var error: URLError.Code? = nil
        }
        private static let lock = NSLock()
        nonisolated(unsafe) private static var replies: [Reply] = []
        nonisolated(unsafe) private static var captured: [URLRequest] = []

        static func reset(_ values: [Reply]) { lock.withLock { replies = values; captured = [] } }
        static var requests: [URLRequest] { lock.withLock { captured } }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let reply = Self.lock.withLock { () -> Reply in
                Self.captured.append(request)
                return Self.replies.isEmpty ? Reply(status: 500, body: "unexpected request") : Self.replies.removeFirst()
            }
            if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Fixture.self]
        return URLSession(configuration: config)
    }

    @Test func savedReceiptSurvivesProjectLogRoundTripAndLegacyLogs() throws {
        let event = GenerationSpendEvent(transactionId: "transaction", kind: .submitted,
            model: "soul", provider: .higgsfield, transport: .api, endpoint: "higgsfield-ai/soul/v2/standard",
            providerRequestId: Self.id, providerRequestResumable: true, providerReceipt: Self.receipt)
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(GenerationSpendEvent.self, from: encoded)
        #expect(decoded.providerReceipt == Self.receipt)
        try decoded.providerReceipt?.validate()
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "providerReceipt")
        let old = try JSONDecoder().decode(GenerationSpendEvent.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.providerReceipt == nil)
    }

    @Test func credentialsAndEndpointValidation() throws {
        #expect(try HiggsfieldCredentials(" key:secret\n").value == "key:secret")
        for value in ["key", "key:", ":secret", "key:secret:extra", "key:sec\nret"] {
            #expect(throws: (any Error).self) { try HiggsfieldCredentials(value) }
        }
        for path in ["../requests", "https://other.test", "/model", "a//b", "a?b", "a/%2e%2e/b"] {
            #expect(throws: (any Error).self) { try HiggsfieldClient.endpointURL(path) }
        }
        #expect(try HiggsfieldClient.catalogPageURL("http://dash.higgsfield.ai/api/v2/pricing/models/?page=2")?.scheme == "https")
        #expect(throws: (any Error).self) {
            try HiggsfieldClient.catalogPageURL("https://other.test/api/v2/pricing/models/")
        }
    }

    @Test func acceptedJobPollsReturnedReceiptAndImportsOutput() async throws {
        let receiptData = try JSONEncoder().encode(Self.receipt)
        Fixture.reset([
            .init(status: 202, body: String(decoding: receiptData, as: UTF8.self)),
            .init(status: 503, body: "busy"),
            .init(status: 200, body: #"{"status":"queued"}"#),
            .init(status: 200, body: #"{"status":"in_progress"}"#),
            .init(status: 200, body: #"{"status":"completed","video":{"url":"https://cdn.example.com/take.mp4"}}"#)
        ])
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try HiggsfieldClient(apiKey: "test-key:test-secret", session: session, pollInterval: 0)
        let receipt = try await client.submit(endpoint: "bytedance/seedance-2.5/text-to-video", body: Data(#"{"prompt":"compiled"}"#.utf8))
        #expect(receipt == Self.receipt)
        #expect(try await client.output(receipt: receipt, shape: .video) == ["https://cdn.example.com/take.mp4"])
        #expect(Fixture.requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(Fixture.requests.dropFirst().allSatisfy { $0.url == receipt.statusURL })
        #expect(Fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Key test-key:test-secret" })
    }

    @Test func ambiguousSubmissionNeverRetries() async throws {
        for reply in [Fixture.Reply(status: 0, body: "", error: .timedOut), .init(status: 502, body: "gateway"),
                      .init(status: 202, body: #"{"status":"queued"}"#)] {
            Fixture.reset([reply])
            let session = session()
            defer { session.invalidateAndCancel() }
            let client = try HiggsfieldClient(apiKey: "key:secret", session: session)
            await #expect(throws: HiggsfieldClient.SubmissionUncertain.self) {
                try await client.submit(endpoint: "higgsfield-ai/soul/v2/standard", body: Data(#"{"prompt":"compiled"}"#.utf8))
            }
            #expect(Fixture.requests.count == 1)
        }
    }

    @Test func receiptCannotLeakCredentialsToForeignHost() async throws {
        Fixture.reset([])
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try HiggsfieldClient(apiKey: "key:secret", session: session)
        let receipt = HiggsfieldJobReceipt(requestID: Self.id,
            statusURL: URL(string: "https://other.test/requests/\(Self.id)/status")!, cancelURL: Self.receipt.cancelURL)
        await #expect(throws: (any Error).self) { try await client.output(receipt: receipt, shape: .video) }
        #expect(Fixture.requests.isEmpty)
    }

    @Test func terminalStatesStopWithoutResubmission() async throws {
        for status in ["failed", "nsfw", "canceled"] {
            Fixture.reset([.init(status: 200, body: "{\"status\":\"\(status)\"}")])
            let session = session()
            defer { session.invalidateAndCancel() }
            let client = try HiggsfieldClient(apiKey: "key:secret", session: session, pollInterval: 0)
            await #expect(throws: HiggsfieldClient.TerminalFailure.self) {
                try await client.output(receipt: Self.receipt, shape: .images)
            }
            #expect(Fixture.requests.count == 1)
        }
    }

    @Test func cancellationUsesQueuedOnlyContract() async throws {
        Fixture.reset([.init(status: 202, body: ""), .init(status: 400, body: #"{"detail":"already processing"}"#)])
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try HiggsfieldClient(apiKey: "key:secret", session: session)
        try await client.cancel(receipt: Self.receipt)
        await #expect(throws: GenerationBackendError.self) { try await client.cancel(receipt: Self.receipt) }
        #expect(Fixture.requests.allSatisfy { $0.httpMethod == "POST" && $0.url == Self.receipt.cancelURL })
    }

    @Test func uploadReplaysStorageHeadersWithoutAPISecret() async throws {
        Fixture.reset([
            .init(status: 200, body: #"{"upload_url":"https://storage.example.com/input","public_url":"https://cdn.example.com/input.png","upload_headers":{"Content-Type":"image/png","x-amz-tagging":"retention=temporary"}}"#),
            .init(status: 200, body: "")
        ])
        let session = session()
        defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([137, 80, 78, 71]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let client = try HiggsfieldClient(apiKey: "key:secret", session: session)
        #expect(try await client.uploadReference(fileURL: file) == "https://cdn.example.com/input.png")
        let requests = Fixture.requests
        #expect(requests.count == 2)
        let upload = try #require(requests.last)
        #expect(upload.httpMethod == "PUT")
        #expect(upload.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(upload.value(forHTTPHeaderField: "x-amz-tagging") == "retention=temporary")
        #expect(upload.value(forHTTPHeaderField: "Content-Type") == "image/png")
    }

    @Test func liveCatalogPaginatesAndChecksCredentialsWithoutGeneration() async throws {
        Fixture.reset([
            .init(status: 200, body: #"{"next":"http://dash.higgsfield.ai/api/v2/pricing/models/?page=2","results":[{"availability_state":"available","modes":[{"slug":"bytedance/seedance-2.5/text-to-video","availability_state":"available"},{"slug":"blocked","availability_state":"blocked"}]}]}"#),
            .init(status: 200, body: #"{"next":null,"results":[{"availability_state":"available","modes":[{"slug":"higgsfield-ai/soul/v2/standard","availability_state":"available"}]}]}"#),
            .init(status: 200, body: #"{"credits":"1.5","usd":"0.0032"}"#)
        ])
        let session = session()
        defer { session.invalidateAndCancel() }
        let ids = try await HiggsfieldClient(apiKey: "key:secret", session: session).availableModelIDs()
        #expect(ids == ["bytedance/seedance-2.5/text-to-video", "higgsfield-ai/soul/v2/standard"])
        #expect(Fixture.requests.prefix(2).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(Fixture.requests.last?.url?.path.hasPrefix("/estimate/") == true)
    }

    @Test @MainActor func balanceRejectionIsNotCredentialRejection() {
        let error = GenerationBackendError.api(status: 403, code: "higgsfield_403", message: "balance")
        #expect(!DirectImageDiscovery.isAuthenticationFailure(error, provider: .higgsfield))
        #expect(DirectImageDiscovery.isAuthenticationFailure(error, provider: .fal))
    }

    @Test func malformedEstimateFailsClosed() async throws {
        Fixture.reset([.init(status: 200, body: #"{"usd":"NaN"}"#)])
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try HiggsfieldClient(apiKey: "key:secret", session: session)
        await #expect(throws: (any Error).self) {
            try await client.estimate(endpoint: "higgsfield-ai/soul/v2/standard", body: Data("{}".utf8))
        }
    }
}
