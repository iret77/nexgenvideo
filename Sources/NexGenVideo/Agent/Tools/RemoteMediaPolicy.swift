import AVFoundation
import Darwin
import Foundation
import ImageIO

enum RemoteMediaPolicy {
    typealias Resolver = @Sendable (_ host: String) throws -> Set<String>

    enum PolicyError: LocalizedError, Equatable {
        case invalidURL(String)
        case blockedHost(String)
        case resolutionFailed(String)
        case redirectLimit
        case redirectLoop
        case responseTooLarge
        case invalidPayload(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let detail): "Remote media URL rejected: \(detail)"
            case .blockedHost(let host): "Remote media host is not public: \(host)"
            case .resolutionFailed(let host): "Remote media host couldn't be resolved: \(host)"
            case .redirectLimit: "Remote media redirected too many times."
            case .redirectLoop: "Remote media entered a redirect loop."
            case .responseTooLarge: "Remote media exceeds the configured import limit."
            case .invalidPayload(let detail): "Remote media payload is invalid: \(detail)"
            }
        }
    }

    static func validate(
        _ url: URL,
        resolver: Resolver = systemResolve
    ) throws -> Set<String> {
        guard url.scheme?.lowercased() == "https" else {
            throw PolicyError.invalidURL("HTTPS is required.")
        }
        guard url.user(percentEncoded: false) == nil,
              url.password(percentEncoded: false) == nil else {
            throw PolicyError.invalidURL("embedded credentials are not allowed.")
        }
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            throw PolicyError.invalidURL("the host is missing.")
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !isLocalHostname(host) else {
            throw PolicyError.blockedHost(host)
        }
        let addresses = try resolver(host)
        guard !addresses.isEmpty else {
            throw PolicyError.resolutionFailed(host)
        }
        guard addresses.allSatisfy(isPublicAddress) else {
            throw PolicyError.blockedHost(host)
        }
        return addresses
    }

    static func systemResolve(_ host: String) throws -> Set<String> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_ADDRCONFIG
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw PolicyError.resolutionFailed(host)
        }
        defer { freeaddrinfo(first) }

        var addresses: Set<String> = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameStatus = getnameinfo(
                info.ai_addr,
                info.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if nameStatus == 0 {
                addresses.insert(String(cString: buffer))
            }
            cursor = info.ai_next
        }
        return addresses
    }

    static func isPublicAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            return isPublicIPv4(UInt32(bigEndian: ipv4.s_addr))
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if Array(bytes.prefix(12)) == Array(repeating: UInt8(0), count: 10) + [0xff, 0xff] {
                let value = bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return isPublicIPv4(value)
            }
            guard bytes[0] & 0xe0 == 0x20 else { return false }
            if Array(bytes[0...3]) == [0x20, 0x01, 0x0d, 0xb8] { return false }
            return true
        }
        return false
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".home.arpa")
            || !host.contains(".")
    }

    private static func isPublicIPv4(_ value: UInt32) -> Bool {
        func matches(_ network: UInt32, _ prefix: UInt32) -> Bool {
            let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - prefix)
            return value & mask == network & mask
        }
        let blocked: [(UInt32, UInt32)] = [
            (0x00000000, 8),
            (0x0a000000, 8),
            (0x64400000, 10),
            (0x7f000000, 8),
            (0xa9fe0000, 16),
            (0xac100000, 12),
            (0xc0000000, 24),
            (0xc0000200, 24),
            (0xc0a80000, 16),
            (0xc6120000, 15),
            (0xc6336400, 24),
            (0xcb007100, 24),
            (0xe0000000, 4),
            (0xf0000000, 4),
        ]
        return !blocked.contains { matches($0.0, $0.1) }
    }
}

enum RemoteMediaDownloader {
    struct Download: Sendable {
        let temporaryURL: URL
        let response: HTTPURLResponse
    }

    static func download(
        _ url: URL,
        maxBytes: Int64,
        timeout: TimeInterval,
        resolver: @escaping RemoteMediaPolicy.Resolver = RemoteMediaPolicy.systemResolve,
        configuration: URLSessionConfiguration? = nil,
        verifyPeerAddress: Bool = true
    ) async throws -> Download {
        _ = try RemoteMediaPolicy.validate(url, resolver: resolver)
        let delegate = Delegate(
            maxBytes: maxBytes,
            resolver: resolver,
            initialURL: url,
            verifyPeerAddress: verifyPeerAddress
        )
        let config = configuration ?? .ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        do {
            let (downloadedURL, response) = try await session.download(
                for: request,
                delegate: delegate
            )
            if let error = delegate.failure { throw error }
            let temporaryURL = try delegate.retainDownloadedFile(at: downloadedURL)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteMediaPolicy.PolicyError.invalidPayload("the response is not HTTP.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw RemoteMediaPolicy.PolicyError.invalidPayload(
                    "the server returned HTTP \(http.statusCode)."
                )
            }
            guard let finalURL = http.url else {
                throw RemoteMediaPolicy.PolicyError.invalidPayload("the final URL is missing.")
            }
            _ = try RemoteMediaPolicy.validate(finalURL, resolver: resolver)
            let size = (try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else {
                throw RemoteMediaPolicy.PolicyError.invalidPayload("the response is empty.")
            }
            guard Int64(size) <= maxBytes else {
                throw RemoteMediaPolicy.PolicyError.responseTooLarge
            }
            return Download(temporaryURL: temporaryURL, response: http)
        } catch {
            if let temporaryURL = delegate.downloadedFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            if let failure = delegate.failure { throw failure }
            throw error
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let maxBytes: Int64
        private let resolver: RemoteMediaPolicy.Resolver
        private let verifyPeerAddress: Bool
        private let lock = NSLock()
        private var redirectCount = 0
        private var visited: Set<String>
        private var storedFailure: (any Error)?

        var failure: (any Error)? {
            lock.withLock { storedFailure }
        }

        var downloadedFile: URL? {
            lock.withLock { storedDownloadURL }
        }

        private var storedDownloadURL: URL?

        func retainDownloadedFile(at location: URL) throws -> URL {
            try lock.withLock {
                if let storedDownloadURL { return storedDownloadURL }
                guard FileManager.default.fileExists(atPath: location.path) else {
                    throw RemoteMediaPolicy.PolicyError.invalidPayload(
                        "the temporary download is missing."
                    )
                }
                let retained = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "ngv-remote-\(UUID().uuidString)",
                    isDirectory: false
                )
                try FileManager.default.moveItem(at: location, to: retained)
                storedDownloadURL = retained
                return retained
            }
        }

        init(
            maxBytes: Int64,
            resolver: @escaping RemoteMediaPolicy.Resolver,
            initialURL: URL,
            verifyPeerAddress: Bool
        ) {
            self.maxBytes = maxBytes
            self.resolver = resolver
            self.verifyPeerAddress = verifyPeerAddress
            self.visited = [initialURL.absoluteString]
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url else {
                fail(RemoteMediaPolicy.PolicyError.invalidURL("redirect URL is missing."))
                completionHandler(nil)
                return
            }
            do {
                try lock.withLock {
                    redirectCount += 1
                    guard redirectCount <= 5 else {
                        throw RemoteMediaPolicy.PolicyError.redirectLimit
                    }
                    guard visited.insert(url.absoluteString).inserted else {
                        throw RemoteMediaPolicy.PolicyError.redirectLoop
                    }
                }
                _ = try RemoteMediaPolicy.validate(url, resolver: resolver)
                completionHandler(request)
            } catch {
                fail(error)
                completionHandler(nil)
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            if totalBytesExpectedToWrite > maxBytes || totalBytesWritten > maxBytes {
                fail(RemoteMediaPolicy.PolicyError.responseTooLarge)
                downloadTask.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            do {
                _ = try retainDownloadedFile(at: location)
            } catch {
                fail(error)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            guard verifyPeerAddress else { return }
            guard !metrics.transactionMetrics.isEmpty else {
                fail(RemoteMediaPolicy.PolicyError.resolutionFailed(
                    task.currentRequest?.url?.host ?? "remote host"
                ))
                return
            }
            for transaction in metrics.transactionMetrics {
                if transaction.isProxyConnection {
                    fail(RemoteMediaPolicy.PolicyError.blockedHost(
                        "proxied remote connection"
                    ))
                    return
                }
                guard let address = transaction.remoteAddress,
                      RemoteMediaPolicy.isPublicAddress(address) else {
                    fail(RemoteMediaPolicy.PolicyError.blockedHost(
                        transaction.remoteAddress ?? "unknown peer"
                    ))
                    return
                }
            }
        }

        private func fail(_ error: any Error) {
            lock.withLock {
                if storedFailure == nil { storedFailure = error }
            }
        }
    }
}

enum RemoteMediaPayloadValidator {
    static func validate(_ url: URL, expectedType: ClipType) async throws {
        switch expectedType {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw RemoteMediaPolicy.PolicyError.invalidPayload(
                    "the file is not a decodable image."
                )
            }
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.load(.tracks)
            let mediaType: AVMediaType = expectedType == .video ? .video : .audio
            guard tracks.contains(where: { $0.mediaType == mediaType }) else {
                throw RemoteMediaPolicy.PolicyError.invalidPayload(
                    "the file contains no \(expectedType.rawValue) track."
                )
            }
        case .lottie:
            guard LottieVideoGenerator.isLottie(at: url) else {
                throw RemoteMediaPolicy.PolicyError.invalidPayload(
                    "the file is not a Lottie animation."
                )
            }
        case .document:
            guard let data = try? Data(contentsOf: url),
                  !data.isEmpty,
                  String(data: data, encoding: .utf8) != nil else {
                throw RemoteMediaPolicy.PolicyError.invalidPayload(
                    "the file is not a UTF-8 document."
                )
            }
        case .text:
            throw RemoteMediaPolicy.PolicyError.invalidPayload(
                "text clips cannot be imported from a URL."
            )
        }
    }
}
