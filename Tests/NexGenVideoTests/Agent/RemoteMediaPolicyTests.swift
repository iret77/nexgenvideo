import Foundation
import Testing
@testable import NexGenVideo

@Suite("Remote media policy", .serialized)
struct RemoteMediaPolicyTests {
    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        enum Route: Sendable {
            case response(status: Int, headers: [String: String], data: Data)
            case redirect(URL)
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var routes: [URL: Route] = [:]

        static func install(_ routes: [URL: Route]) {
            lock.withLock { self.routes = routes }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url,
                  let route = Self.lock.withLock({ Self.routes[url] }) else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.resourceUnavailable)
                )
                return
            }
            switch route {
            case .response(let status, let headers, let data):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                client?.urlProtocol(
                    self,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed
                )
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .redirect(let destination):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": destination.absoluteString]
                )!
                client?.urlProtocol(
                    self,
                    wasRedirectedTo: URLRequest(url: destination),
                    redirectResponse: response
                )
            }
        }

        override func stopLoading() {}
    }

    private final class ResolutionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        return config
    }

    private let publicResolver: RemoteMediaPolicy.Resolver = { _ in ["93.184.216.34"] }

    @Test("private, loopback, link-local, reserved, and local names are rejected")
    func rejectsNonPublicTargets() {
        let blocked = [
            "127.0.0.1",
            "10.0.0.1",
            "169.254.1.2",
            "192.168.1.1",
            "100.64.0.1",
            "192.0.2.1",
            "::1",
            "fe80::1",
            "2001:db8::1",
        ]
        for address in blocked {
            #expect(RemoteMediaPolicy.isPublicAddress(address) == false)
        }
        #expect(RemoteMediaPolicy.isPublicAddress("93.184.216.34"))
        #expect(RemoteMediaPolicy.isPublicAddress("2606:4700:4700::1111"))
        #expect(throws: RemoteMediaPolicy.PolicyError.self) {
            _ = try RemoteMediaPolicy.validate(
                URL(string: "https://localhost/file.png")!,
                resolver: publicResolver
            )
        }
    }

    @Test("HTTPS to HTTP redirect is rejected")
    func rejectsHTTPRedirect() async {
        let start = URL(string: "https://public.test/start.png")!
        let destination = URL(string: "http://public.test/end.png")!
        FixtureURLProtocol.install([start: .redirect(destination)])

        await #expect(throws: RemoteMediaPolicy.PolicyError.self) {
            _ = try await RemoteMediaDownloader.download(
                start,
                maxBytes: 1024,
                timeout: 5,
                resolver: publicResolver,
                configuration: configuration(),
                verifyPeerAddress: false
            )
        }
    }

    @Test("redirect to a private address is rejected")
    func rejectsPrivateRedirect() async {
        let start = URL(string: "https://public.test/start.png")!
        let destination = URL(string: "https://private.test/end.png")!
        FixtureURLProtocol.install([start: .redirect(destination)])
        let resolver: RemoteMediaPolicy.Resolver = {
            $0 == "private.test" ? ["10.0.0.2"] : ["93.184.216.34"]
        }

        await #expect(throws: RemoteMediaPolicy.PolicyError.self) {
            _ = try await RemoteMediaDownloader.download(
                start,
                maxBytes: 1024,
                timeout: 5,
                resolver: resolver,
                configuration: configuration(),
                verifyPeerAddress: false
            )
        }
    }

    @Test("an allowed redirect chain downloads once")
    func allowsPublicRedirect() async throws {
        let start = URL(string: "https://public.test/start.bin")!
        let destination = URL(string: "https://cdn.test/end.bin")!
        FixtureURLProtocol.install([
            start: .redirect(destination),
            destination: .response(
                status: 200,
                headers: ["Content-Length": "3"],
                data: Data("abc".utf8)
            ),
        ])

        let download = try await RemoteMediaDownloader.download(
            start,
            maxBytes: 1024,
            timeout: 5,
            resolver: publicResolver,
            configuration: configuration(),
            verifyPeerAddress: false
        )
        defer { try? FileManager.default.removeItem(at: download.temporaryURL) }
        #expect(try Data(contentsOf: download.temporaryURL) == Data("abc".utf8))
        #expect(download.response.url == destination)
    }

    @Test("a redirect loop is rejected")
    func rejectsRedirectLoop() async {
        let first = URL(string: "https://public.test/first.bin")!
        let second = URL(string: "https://public.test/second.bin")!
        FixtureURLProtocol.install([
            first: .redirect(second),
            second: .redirect(first),
        ])

        await #expect(throws: RemoteMediaPolicy.PolicyError.self) {
            _ = try await RemoteMediaDownloader.download(
                first,
                maxBytes: 1024,
                timeout: 5,
                resolver: publicResolver,
                configuration: configuration(),
                verifyPeerAddress: false
            )
        }
    }

    @Test("more than five redirects are rejected")
    func rejectsRedirectLimit() async {
        let urls = (0...6).map {
            URL(string: "https://public.test/hop-\($0).bin")!
        }
        var routes: [URL: FixtureURLProtocol.Route] = [:]
        for index in 0..<6 {
            routes[urls[index]] = .redirect(urls[index + 1])
        }
        routes[urls[6]] = .response(
            status: 200,
            headers: ["Content-Length": "3"],
            data: Data("abc".utf8)
        )
        FixtureURLProtocol.install(routes)

        await #expect(throws: RemoteMediaPolicy.PolicyError.self) {
            _ = try await RemoteMediaDownloader.download(
                urls[0],
                maxBytes: 1024,
                timeout: 5,
                resolver: publicResolver,
                configuration: configuration(),
                verifyPeerAddress: false
            )
        }
    }

    @Test("a public-to-private DNS answer change is rejected after transfer")
    func rejectsRebinding() async {
        let url = URL(string: "https://rebind.test/file.bin")!
        FixtureURLProtocol.install([
            url: .response(
                status: 200,
                headers: ["Content-Length": "3"],
                data: Data("abc".utf8)
            ),
        ])
        let resolutions = ResolutionCounter()
        let resolver: RemoteMediaPolicy.Resolver = { _ in
            resolutions.next() == 1 ? ["93.184.216.34"] : ["10.0.0.2"]
        }

        await #expect(throws: RemoteMediaPolicy.PolicyError.self) {
            _ = try await RemoteMediaDownloader.download(
                url,
                maxBytes: 1024,
                timeout: 5,
                resolver: resolver,
                configuration: configuration(),
                verifyPeerAddress: false
            )
        }
    }

    @Test("oversize content is rejected")
    func rejectsOversize() async {
        let url = URL(string: "https://public.test/large.bin")!
        FixtureURLProtocol.install([
            url: .response(
                status: 200,
                headers: ["Content-Length": "2048"],
                data: Data(repeating: 0x61, count: 2048)
            ),
        ])

        await #expect(throws: RemoteMediaPolicy.PolicyError.self) {
            _ = try await RemoteMediaDownloader.download(
                url,
                maxBytes: 32,
                timeout: 5,
                resolver: publicResolver,
                configuration: configuration(),
                verifyPeerAddress: false
            )
        }
    }

    @Test("HTML with an image extension is rejected before registration")
    func rejectsWrongPayload() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-media-\(UUID().uuidString).png"
        )
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("<html>error</html>".utf8).write(to: file)

        await #expect(throws: RemoteMediaPolicy.PolicyError.self) {
            try await RemoteMediaPayloadValidator.validate(file, expectedType: .image)
        }
    }
}
