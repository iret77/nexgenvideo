import Foundation
import Testing

@testable import NexGenVideo

@Suite("Google image transport", .serialized)
struct GoogleImageClientTests {
    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var responses: [(status: Int, body: Data)] = []
        nonisolated(unsafe) private static var responseIndex = 0
        nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
        nonisolated(unsafe) private static var capturedRequestBodies: [Data?] = []

        static func install(status: Int, body: String) {
            install([(status: status, body: body)])
        }

        static func install(_ fixtures: [(status: Int, body: String)]) {
            lock.withLock {
                responses = fixtures.map { ($0.status, Data($0.body.utf8)) }
                responseIndex = 0
                capturedRequests = []
                capturedRequestBodies = []
            }
        }

        static func request() -> URLRequest? {
            lock.withLock { capturedRequests.last }
        }

        static func requests() -> [URLRequest] {
            lock.withLock { capturedRequests }
        }

        static func requestBody() -> Data? {
            lock.withLock { capturedRequestBodies.last ?? nil }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let requestBody = Self.body(of: request)
            let fixture = Self.lock.withLock { () -> (Int, Data) in
                Self.capturedRequests.append(request)
                Self.capturedRequestBodies.append(requestBody)
                guard Self.responseIndex < Self.responses.count else {
                    return (500, Data(#"{"error":{"message":"Missing test fixture"}}"#.utf8))
                }
                let response = Self.responses[Self.responseIndex]
                Self.responseIndex += 1
                return (response.status, response.body)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: fixture.0,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixture.1)
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

    private func catalogPage(_ names: [String], nextPageToken: String? = nil) throws -> String {
        var object: [String: Any] = ["models": names.map { ["name": $0] }]
        if let nextPageToken { object["nextPageToken"] = nextPageToken }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test("model discovery authenticates by header and normalizes model names")
    func modelCatalogUsesSavedKey() async throws {
        FixtureURLProtocol.install(
            status: 200,
            body: #"{"models":[{"name":"models/gemini-2.5-flash-image"},{"name":"gemini-3-pro-image"}]}"#
        )
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        let models = try await GoogleImageClient(
            apiKey: "google-secret",
            session: testSession
        ).availableModelIds()

        #expect(models == ["gemini-2.5-flash-image", "gemini-3-pro-image"])
        #expect(FixtureURLProtocol.request()?.value(forHTTPHeaderField: "x-goog-api-key") == "google-secret")
        #expect(FixtureURLProtocol.request()?.url?.query?.contains("pageSize=200") == true)
    }

    @Test("model discovery consumes every page before publishing the inventory")
    func modelCatalogPaginates() async throws {
        FixtureURLProtocol.install([
            (
                status: 200,
                body: try catalogPage(["models/gemini-first"], nextPageToken: "next page")
            ),
            (status: 200, body: try catalogPage(["models/gemini-second"])),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        let models = try await GoogleImageClient(
            apiKey: "google-secret",
            session: testSession
        ).availableModelIds()

        #expect(models == ["gemini-first", "gemini-second"])
        let requests = FixtureURLProtocol.requests()
        #expect(requests.count == 2)
        let lastRequestURL = try #require(requests.last?.url)
        let queryItems = try #require(
            URLComponents(url: lastRequestURL, resolvingAgainstBaseURL: false)?
                .queryItems
        )
        #expect(queryItems.contains(URLQueryItem(name: "pageToken", value: "next page")))
    }

    @MainActor
    @Test("an empty catalog page never follows its continuation token")
    func emptyPageWithTokenFailsBeforeNextRequest() async throws {
        FixtureURLProtocol.install([
            (
                status: 200,
                body: try catalogPage(["models/partial"], nextPageToken: "empty-page")
            ),
            (status: 200, body: try catalogPage([], nextPageToken: "must-not-load")),
            (status: 200, body: try catalogPage(["models/must-not-load"])),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        do {
            _ = try await GoogleImageClient(
                apiKey: "google-secret",
                session: testSession
            ).availableModelIds()
            Issue.record("Expected empty-page continuation failure")
        } catch {
            #expect(error.localizedDescription.contains("empty but includes nextPageToken"))
            #expect(DirectImageDiscovery.isTransientFailure(error))
            #expect(DirectImageDiscovery.preservesLastKnownGood(
                after: .transientFailure(error.localizedDescription),
                currentModelCount: 3
            ))
        }
        #expect(FixtureURLProtocol.requests().count == 2)
    }

    @Test("a terminal empty catalog page remains complete")
    func terminalEmptyPageIsComplete() async throws {
        FixtureURLProtocol.install(status: 200, body: try catalogPage([]))
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        let models = try await GoogleImageClient(
            apiKey: "google-secret",
            session: testSession
        ).availableModelIds()

        #expect(models.isEmpty)
        #expect(FixtureURLProtocol.requests().count == 1)
    }

    @Test("a full page without a continuation token fails closed")
    func fullPageWithoutTokenFails() async throws {
        let fullPage = (0..<GoogleImageClient.catalogPageSize).map { "models/model-\($0)" }
        FixtureURLProtocol.install(status: 200, body: try catalogPage(fullPage))
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        do {
            _ = try await GoogleImageClient(
                apiKey: "google-secret",
                session: testSession
            ).availableModelIds()
            Issue.record("Expected the incomplete catalog to fail")
        } catch let error as GenerationBackendError {
            guard case .transport(let message) = error else {
                Issue.record("Expected a transport error, got \(error.localizedDescription)")
                return
            }
            #expect(message.contains("omits nextPageToken"))
        }
    }

    @Test("a repeated continuation token fails closed")
    func repeatedPageTokenFails() async throws {
        FixtureURLProtocol.install([
            (status: 200, body: try catalogPage(["models/first"], nextPageToken: "repeat")),
            (status: 200, body: try catalogPage(["models/second"], nextPageToken: "repeat")),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        do {
            _ = try await GoogleImageClient(
                apiKey: "google-secret",
                session: testSession
            ).availableModelIds()
            Issue.record("Expected the repeated token to fail")
        } catch let error as GenerationBackendError {
            guard case .transport(let message) = error else {
                Issue.record("Expected a transport error, got \(error.localizedDescription)")
                return
            }
            #expect(message.contains("repeats nextPageToken"))
            #expect(FixtureURLProtocol.requests().count == 2)
        }
    }

    @Test("catalog pagination stops at its safety limit without publishing")
    func pageLimitFails() async throws {
        let fixtures = try (0..<GoogleImageClient.catalogPageLimit).map { page in
            (
                status: 200,
                body: try catalogPage(["models/model-\(page)"], nextPageToken: "token-\(page)")
            )
        }
        FixtureURLProtocol.install(fixtures)
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        do {
            _ = try await GoogleImageClient(
                apiKey: "google-secret",
                session: testSession
            ).availableModelIds()
            Issue.record("Expected the page limit to fail")
        } catch let error as GenerationBackendError {
            guard case .transport(let message) = error else {
                Issue.record("Expected a transport error, got \(error.localizedDescription)")
                return
            }
            #expect(message.contains("page safety limit"))
            #expect(FixtureURLProtocol.requests().count == GoogleImageClient.catalogPageLimit)
        }
    }

    @Test("one malformed model entry rejects the entire catalog")
    func malformedCatalogEntryFails() async throws {
        FixtureURLProtocol.install(
            status: 200,
            body: #"{"models":[{"name":"models/valid"},{"displayName":"missing name"}]}"#
        )
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        do {
            _ = try await GoogleImageClient(
                apiKey: "google-secret",
                session: testSession
            ).availableModelIds()
            Issue.record("Expected the malformed model entry to fail")
        } catch let error as GenerationBackendError {
            guard case .transport(let message) = error else {
                Issue.record("Expected a transport error, got \(error.localizedDescription)")
                return
            }
            #expect(message.contains("entry 2 has no valid name"))
        }
    }

    @MainActor
    @Test("credential rejection is classified as an API authentication failure")
    func rejectedCredentialIsNotTransient() async throws {
        FixtureURLProtocol.install(
            status: 401,
            body: #"{"error":{"message":"API key rejected"}}"#
        )
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        do {
            _ = try await GoogleImageClient(
                apiKey: "rejected",
                session: testSession
            ).availableModelIds()
            Issue.record("Expected Google authentication failure")
        } catch let error as GenerationBackendError {
            guard case .api(let status, let code, let message) = error else {
                Issue.record("Expected an API error, got \(error.localizedDescription)")
                return
            }
            #expect(status == 401)
            #expect(code == "401")
            #expect(message.contains("API key rejected"))
            #expect(DirectImageDiscovery.isAuthenticationFailure(error))
        }
    }

    @Test("malformed successful catalog cannot replace last-known-good inventory")
    func malformedCatalogFails() async throws {
        FixtureURLProtocol.install(status: 200, body: #"{"models":"invalid"}"#)
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        do {
            _ = try await GoogleImageClient(
                apiKey: "google-secret",
                session: testSession
            ).availableModelIds()
            Issue.record("Expected malformed catalog failure")
        } catch let error as GenerationBackendError {
            guard case .transport(let message) = error else {
                Issue.record("Expected a transport error, got \(error.localizedDescription)")
                return
            }
            #expect(message.contains("malformed model catalog"))
        }
    }

    @MainActor
    @Test("approved references load completely and preserve order")
    func referencesLoadAllOrNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")
        try Data([1, 2]).write(to: first)
        try Data([3, 4]).write(to: second)

        let loaded = try GenerationService.referenceBytes([first.path, second.path])

        #expect(loaded == [Data([1, 2]), Data([3, 4])])
    }

    @MainActor
    @Test("an unreadable approved reference fails the entire load")
    func missingReferenceFailsBeforeSubmission() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readable = directory.appendingPathComponent("readable.png")
        let missing = directory.appendingPathComponent("missing-approved.png")
        try Data([1, 2]).write(to: readable)

        do {
            _ = try GenerationService.referenceBytes([readable.path, missing.path])
            Issue.record("Expected the approved reference set to fail")
        } catch {
            #expect(error.localizedDescription.contains("missing-approved.png"))
        }
    }

    @Test("a prepared request stays undispatched until explicitly sent")
    func preparedRequestDispatchesWithoutRebuilding() async throws {
        FixtureURLProtocol.install(
            status: 200,
            body: #"{"candidates":[{"content":{"parts":[{"inlineData":{"data":"AQI="}}]}}]}"#
        )
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = GoogleImageClient(apiKey: "google-secret", session: testSession)
        let reference = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        ))

        let prepared = try await client.prepareGeminiImageRequest(
            model: "gemini-image",
            prompt: "Prepared prompt",
            aspectRatio: "16:9",
            referenceImages: [reference]
        )

        #expect(FixtureURLProtocol.requests().isEmpty)
        #expect(try await client.geminiImage(prepared: prepared) == [Data([1, 2])])
        let request = try #require(FixtureURLProtocol.request())
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "google-secret")
        let body = try #require(FixtureURLProtocol.requestBody())
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let config = try #require(object["generationConfig"] as? [String: Any])
        #expect((config["imageConfig"] as? [String: String])?["aspectRatio"] == "16:9")
        let contents = try #require(object["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        let inline = try #require(parts.last?["inline_data"] as? [String: String])
        #expect(inline["mime_type"] == "image/png")
        #expect(inline["data"] == reference.base64EncodedString())
    }

    @MainActor
    @Test("a readable unsupported reference fails before any request")
    func readableUnsupportedReferenceFailsPreflight() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsupported = directory.appendingPathComponent("reference.bmp")
        try Data([0x42, 0x4D] + Array(repeating: 0, count: 14)).write(to: unsupported)
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        FixtureURLProtocol.install(status: 200, body: #"{"candidates":[]}"#)
        let references = try GenerationService.referenceBytes([unsupported.path])

        do {
            _ = try await GoogleImageClient(
                apiKey: "google-secret",
                session: testSession
            ).prepareGeminiImageRequest(
                model: "gemini-image",
                prompt: "Prompt",
                referenceImages: references
            )
            Issue.record("Expected unsupported reference preflight to fail")
        } catch let error as GoogleImageClient.ClientError {
            #expect(error.localizedDescription.contains("not a PNG, JPEG, WebP or HEIC"))
            #expect(FixtureURLProtocol.requests().isEmpty)
        }
    }

    @MainActor
    @Test("a corrupt readable reference set fails before any request")
    func readableCorruptReferenceFailsPreflight() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = directory.appendingPathComponent("valid.png")
        let corrupt = directory.appendingPathComponent("corrupt.png")
        try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )).write(to: valid)
        try Data(
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
                + Array(repeating: 0, count: 24)
        ).write(to: corrupt)
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        FixtureURLProtocol.install(status: 200, body: #"{"candidates":[]}"#)
        let references = try GenerationService.referenceBytes([valid.path, corrupt.path])

        do {
            _ = try await GoogleImageClient(
                apiKey: "google-secret",
                session: testSession
            ).prepareGeminiImageRequest(
                model: "gemini-image",
                prompt: "Prompt",
                referenceImages: references
            )
            Issue.record("Expected corrupt reference preflight to fail")
        } catch let error as GoogleImageClient.ClientError {
            #expect(error.localizedDescription.contains("corrupt"))
            #expect(FixtureURLProtocol.requests().isEmpty)
        }
    }
}
