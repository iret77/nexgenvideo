import Foundation
import UniformTypeIdentifiers

enum MireloOperation: String, Codable, CaseIterable, Sendable {
    case textToSFX = "text-to-sfx"
    case videoToSFX = "video-to-sfx"
    case extend
    case inpaint
    case audioToMIDI = "audio-to-midi"

    var preflightPath: String {
        switch self {
        case .textToSFX: "/v3/text-to-sfx/generations/preflight"
        case .videoToSFX: "/v3/video-to-sfx/generations/preflight"
        case .extend: "/v3/extend/edits/preflight"
        case .inpaint: "/v3/inpaint/edits/preflight"
        case .audioToMIDI: "/v2/audio-to-midi/v1.0/preflight"
        }
    }

    var createPath: String {
        switch self {
        case .textToSFX: "/v3/text-to-sfx/generations"
        case .videoToSFX: "/v3/video-to-sfx/generations"
        case .extend: "/v3/extend/edits"
        case .inpaint: "/v3/inpaint/edits"
        case .audioToMIDI: "/v2/audio-to-midi/v1.0/jobs"
        }
    }

    func pollPath(jobID: String) -> String {
        switch self {
        case .textToSFX: "/v3/text-to-sfx/generations/\(jobID)"
        case .videoToSFX: "/v3/video-to-sfx/generations/\(jobID)"
        case .extend: "/v3/extend/edits/\(jobID)"
        case .inpaint: "/v3/inpaint/edits/\(jobID)"
        case .audioToMIDI: "/v2/audio-to-midi/v1.0/jobs/\(jobID)"
        }
    }

    var usesIdempotencyKey: Bool { self != .audioToMIDI }
}

struct MireloRange: Codable, Sendable, Equatable {
    let min: Int?
    let max: Int?
    let minWithLoop: Int?
    let maxWithLoop: Int?
    let maxWithPreserveSpeech: Int?

    private enum CodingKeys: String, CodingKey {
        case min, max
        case minWithLoop = "min_with_loop"
        case maxWithLoop = "max_with_loop"
        case maxWithPreserveSpeech = "max_with_preserve_speech"
    }
}

struct MireloOperationLimits: Codable, Sendable, Equatable {
    let durationMs: MireloRange?
    let prependDurationMs: MireloRange?
    let appendDurationMs: MireloRange?
    let regionStartMs: MireloRange?
    let regionWidthMs: MireloRange?
    let numVariants: MireloRange?
    let controls: [String]?
    private enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms"
        case prependDurationMs = "prepend_duration_ms"
        case appendDurationMs = "append_duration_ms"
        case regionStartMs = "region_start_ms"
        case regionWidthMs = "region_width_ms"
        case numVariants = "num_variants"
        case controls
    }
}

struct MireloModel: Codable, Sendable, Equatable {
    struct Audio: Codable, Sendable, Equatable {
        let sampleRate: Int
        let channels: Int

        private enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate", channels
        }
    }

    let id: String
    let releaseDate: String?
    let status: String
    let audio: Audio
    let maxPromptChars: Int
    let stems: [String]
    let controls: [String]
    let formats: [String]
    let operations: [String: MireloOperationLimits]
    let creditsPerSecond: Double

    private enum CodingKeys: String, CodingKey {
        case id, status, audio, stems, controls, formats, operations
        case releaseDate = "release_date"
        case maxPromptChars = "max_prompt_chars"
        case creditsPerSecond = "credits_per_second"
    }
}

struct MireloAccount: Codable, Sendable, Equatable {
    let id: String
    let accountType: String
    let email: String?
    let creditsAvailable: Int?
    let spendCapacity: Int?
    let billingMode: String
    let provisioningState: String
    let provisioningDeadline: Int64?
    let recoveryAction: String?
    let recoveryURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, email
        case accountType = "account_type"
        case creditsAvailable = "credits_available"
        case spendCapacity = "spend_capacity"
        case billingMode = "billing_mode"
        case provisioningState = "provisioning_state"
        case provisioningDeadline = "provisioning_deadline"
        case recoveryAction = "recovery_action"
        case recoveryURL = "recovery_url"
    }
}

struct MireloCreditRecovery: Codable, Sendable, Equatable {
    let creditsRequired: Int
    let creditsAvailable: Int
    let creditShortfall: Int
    let recoveryAction: String?
    let recoveryURL: URL?
    let provisioningState: String
    let provisioningDeadline: Int64?

    private enum CodingKeys: String, CodingKey {
        case creditsRequired = "credits_required"
        case creditsAvailable = "credits_available"
        case creditShortfall = "credit_shortfall"
        case recoveryAction = "recovery_action"
        case recoveryURL = "recovery_url"
        case provisioningState = "provisioning_state"
        case provisioningDeadline = "provisioning_deadline"
    }

    var canFundRequest: Bool {
        creditShortfall == 0
            && provisioningState == "ready"
            && recoveryAction == nil
    }
}

struct MireloPlannedOutput: Codable, Sendable, Equatable {
    let index: Int
    let type: String
    let label: String?
    let startMs: Int?
    let endMs: Int?
    let credits: Int
    let variantsRequested: Int

    private enum CodingKeys: String, CodingKey {
        case index, type, label, credits
        case startMs = "start_ms"
        case endMs = "end_ms"
        case variantsRequested = "variants_requested"
    }
}

struct MireloPreflight: Codable, Sendable, Equatable {
    let credits: Int
    let estimatedMs: Int?
    let planID: String?
    let planExpiresAt: String?
    let outputs: [MireloPlannedOutput]?
    let creditRecovery: MireloCreditRecovery?
    let billingMode: String?

    private enum CodingKeys: String, CodingKey {
        case credits, outputs
        case estimatedMs = "estimated_ms"
        case planID = "plan_id"
        case planExpiresAt = "plan_expires_at"
        case creditRecovery = "credit_recovery"
        case billingMode = "billing_mode"
        case creditsRequired = "credits_required"
        case creditsAvailable = "credits_available"
        case creditShortfall = "credit_shortfall"
        case recoveryAction = "recovery_action"
        case recoveryURL = "recovery_url"
        case provisioningState = "provisioning_state"
        case provisioningDeadline = "provisioning_deadline"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credits = try container.decode(Int.self, forKey: .credits)
        estimatedMs = try container.decodeIfPresent(Int.self, forKey: .estimatedMs)
        planID = try container.decodeIfPresent(String.self, forKey: .planID)
        planExpiresAt = try container.decodeIfPresent(String.self, forKey: .planExpiresAt)
        outputs = try container.decodeIfPresent([MireloPlannedOutput].self, forKey: .outputs)
        billingMode = try container.decodeIfPresent(String.self, forKey: .billingMode)
        if let nested = try container.decodeIfPresent(
            MireloCreditRecovery.self,
            forKey: .creditRecovery
        ) {
            creditRecovery = nested
        } else if container.contains(.creditsRequired) {
            creditRecovery = MireloCreditRecovery(
                creditsRequired: try container.decode(Int.self, forKey: .creditsRequired),
                creditsAvailable: try container.decode(Int.self, forKey: .creditsAvailable),
                creditShortfall: try container.decode(Int.self, forKey: .creditShortfall),
                recoveryAction: try container.decodeIfPresent(String.self, forKey: .recoveryAction),
                recoveryURL: try container.decodeIfPresent(URL.self, forKey: .recoveryURL),
                provisioningState: try container.decode(String.self, forKey: .provisioningState),
                provisioningDeadline: try container.decodeIfPresent(Int64.self, forKey: .provisioningDeadline)
            )
        } else {
            creditRecovery = nil
        }
    }

    init(
        credits: Int,
        estimatedMs: Int?,
        planID: String? = nil,
        planExpiresAt: String? = nil,
        outputs: [MireloPlannedOutput]? = nil,
        creditRecovery: MireloCreditRecovery? = nil,
        billingMode: String? = nil
    ) {
        self.credits = credits
        self.estimatedMs = estimatedMs
        self.planID = planID
        self.planExpiresAt = planExpiresAt
        self.outputs = outputs
        self.creditRecovery = creditRecovery
        self.billingMode = billingMode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(credits, forKey: .credits)
        try container.encodeIfPresent(estimatedMs, forKey: .estimatedMs)
        try container.encodeIfPresent(planID, forKey: .planID)
        try container.encodeIfPresent(planExpiresAt, forKey: .planExpiresAt)
        try container.encodeIfPresent(outputs, forKey: .outputs)
        try container.encodeIfPresent(creditRecovery, forKey: .creditRecovery)
        try container.encodeIfPresent(billingMode, forKey: .billingMode)
    }
}

struct MireloAssetTicket: Codable, Sendable, Equatable {
    let id: String
    let uploadURL: URL
    let uploadExpiresAt: String
    let maxBytes: Int64
    let fields: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id, fields
        case uploadURL = "upload_url"
        case uploadExpiresAt = "upload_expires_at"
        case maxBytes = "max_bytes"
    }
}

struct MireloCreateReceipt: Codable, Sendable, Equatable {
    let id: String
    let statusURL: String?
    let estimatedMs: Int?

    private enum CodingKeys: String, CodingKey {
        case id, jobID = "job_id", jobURL = "job_url"
        case statusURL = "status_url"
        case estimatedMs = "estimated_ms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decode(String.self, forKey: .jobID)
        statusURL = try c.decodeIfPresent(String.self, forKey: .statusURL)
            ?? c.decodeIfPresent(String.self, forKey: .jobURL)
        estimatedMs = try c.decodeIfPresent(Int.self, forKey: .estimatedMs)
    }

    init(id: String, statusURL: String?, estimatedMs: Int?) {
        self.id = id
        self.statusURL = statusURL
        self.estimatedMs = estimatedMs
    }
}

struct MireloJobResponse: Sendable, Equatable {
    let data: Data
    let retryAfterSeconds: Int?
}

struct MireloHTTPError: LocalizedError, Sendable {
    let status: Int?
    let code: String
    let message: String
    let retryAfterSeconds: Int?
    let requestID: String?
    let retryable: Bool?
    let creditRecovery: MireloCreditRecovery?

    var errorDescription: String? {
        var text = "Mirelo \(code): \(message)"
        if let retryAfterSeconds { text += " Try again in \(retryAfterSeconds) seconds." }
        if let requestID { text += " Request ID: \(requestID)." }
        return text
    }
}

final class MireloClient: Sendable {
    static let apiBaseURL = URL(string: "https://api.mirelo.ai")!

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    init(apiKey: String, baseURL: URL = apiBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    func account() async throws -> MireloAccount {
        try await get("/v3/me", as: MireloAccount.self)
    }

    func models() async throws -> [MireloModel] {
        struct Response: Decodable { let data: [MireloModel] }
        return try await get("/v3/models", as: Response.self).data
    }

    func preflight(operation: MireloOperation, body: Data, durationMS: Int? = nil) async throws -> MireloPreflight {
        if operation == .audioToMIDI {
            guard let durationMS, (1...1_800_000).contains(durationMS) else {
                throw MireloHTTPError(status: nil, code: "invalid_duration", message: "Audio-to-MIDI preflight requires the measured source duration (1 ms to 30 minutes).", retryAfterSeconds: nil, requestID: nil, retryable: false, creditRecovery: nil)
            }
            var components = URLComponents(url: url(operation.preflightPath), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "duration_ms", value: String(durationMS))]
            return try await send(request(url: components.url!, method: "GET"), as: MireloPreflight.self)
        }
        return try await send(jsonRequest(path: operation.preflightPath, method: "POST", body: body), as: MireloPreflight.self)
    }

    func create(operation: MireloOperation, body: Data, idempotencyKey: String?) async throws -> MireloCreateReceipt {
        var req = jsonRequest(path: operation.createPath, method: "POST", body: body)
        if operation.usesIdempotencyKey {
            guard let idempotencyKey, !idempotencyKey.isEmpty else {
                throw MireloHTTPError(status: nil, code: "missing_idempotency_key", message: "This Mirelo v3 create requires a durable idempotency key.", retryAfterSeconds: nil, requestID: nil, retryable: false, creditRecovery: nil)
            }
            req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        let data = try await data(for: req)
        let receipt: MireloCreateReceipt
        if operation == .audioToMIDI {
            struct V2Receipt: Decodable {
                let jobID: String
                let jobURL: String
                let estimatedMs: Int?
                private enum CodingKeys: String, CodingKey {
                    case jobID = "job_id", jobURL = "job_url", estimatedMs = "estimated_ms"
                }
            }
            let value = try decoder.decode(V2Receipt.self, from: data)
            receipt = MireloCreateReceipt(
                id: value.jobID,
                statusURL: value.jobURL,
                estimatedMs: value.estimatedMs
            )
        } else {
            receipt = try decoder.decode(MireloCreateReceipt.self, from: data)
        }
        guard Self.safeJobID(receipt.id) else {
            throw MireloHTTPError(
                status: nil,
                code: "invalid_response",
                message: "Mirelo accepted the request without a safe job identifier.",
                retryAfterSeconds: nil,
                requestID: nil,
                retryable: true,
                creditRecovery: nil
            )
        }
        return receipt
    }

    func job(operation: MireloOperation, id: String) async throws -> MireloJobResponse {
        guard Self.safeJobID(id) else {
            throw MireloHTTPError(
                status: nil,
                code: "invalid_job_id",
                message: "Mirelo returned an invalid job identifier.",
                retryAfterSeconds: nil,
                requestID: nil,
                retryable: false,
                creditRecovery: nil
            )
        }
        try Task.checkCancellation()
        let (data, response) = try await response(
            for: request(path: operation.pollPath(jobID: id), method: "GET")
        )
        return MireloJobResponse(
            data: data,
            retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        )
    }

    func createAsset(for source: URL) async throws -> MireloAssetTicket {
        guard let mime = UTType(filenameExtension: source.pathExtension)?.preferredMIMEType,
              mime.hasPrefix("audio/") || mime.hasPrefix("video/") else {
            throw MireloHTTPError(
                status: nil,
                code: "unsupported_asset_type",
                message: "Mirelo private uploads require a recognized audio or video MIME type.",
                retryAfterSeconds: nil,
                requestID: nil,
                retryable: false,
                creditRecovery: nil
            )
        }
        let body = try JSONSerialization.data(withJSONObject: ["content_type": mime])
        let ticket = try await send(
            jsonRequest(path: "/v3/assets", method: "POST", body: body),
            as: MireloAssetTicket.self
        )
        guard !ticket.id.isEmpty,
              ticket.maxBytes > 0,
              !ticket.uploadExpiresAt.isEmpty,
              !ticket.fields.isEmpty,
              ticket.fields.allSatisfy({ element in
                  let (name, value) = element
                  return !name.isEmpty
                      && !name.contains("\r") && !name.contains("\n")
                      && !value.contains("\r") && !value.contains("\n")
              }) else {
            throw MireloHTTPError(
                status: nil,
                code: "invalid_response",
                message: "Mirelo returned an incomplete private upload ticket.",
                retryAfterSeconds: nil,
                requestID: nil,
                retryable: true,
                creditRecovery: nil
            )
        }
        return ticket
    }

    func upload(_ source: URL, ticket: MireloAssetTicket) async throws {
        guard ticket.uploadURL.scheme?.lowercased() == "https", ticket.uploadURL.host != nil else {
            throw MireloHTTPError(status: nil, code: "unsafe_upload_url", message: "Mirelo returned a non-HTTPS asset upload URL.", retryAfterSeconds: nil, requestID: nil, retryable: false, creditRecovery: nil)
        }
        _ = try RemoteMediaPolicy.validate(ticket.uploadURL)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw MireloHTTPError(status: nil, code: "invalid_asset", message: "The source is not a regular file.", retryAfterSeconds: nil, requestID: nil, retryable: false, creditRecovery: nil)
        }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0, size <= ticket.maxBytes else {
            throw MireloHTTPError(status: nil, code: "asset_too_large", message: "The local source is \(size) bytes; Mirelo's private upload ticket allows \(ticket.maxBytes) bytes. NexGenVideo will not expose it through a public URL.", retryAfterSeconds: nil, requestID: nil, retryable: false, creditRecovery: nil)
        }

        let boundary = "NexGenVideo-\(UUID().uuidString)"
        let folder = AppPaths.ensure(AppPaths.caches.appendingPathComponent("MireloUploads", isDirectory: true))
        let multipart = folder.appendingPathComponent(UUID().uuidString + ".multipart")
        guard FileManager.default.createFile(atPath: multipart.path, contents: nil) else {
            throw MireloHTTPError(
                status: nil,
                code: "asset_staging_failed",
                message: "NexGenVideo could not create the private Mirelo upload body.",
                retryAfterSeconds: nil,
                requestID: nil,
                retryable: false,
                creditRecovery: nil
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: multipart.path
        )
        defer { try? FileManager.default.removeItem(at: multipart) }
        let output = try FileHandle(forWritingTo: multipart)
        defer { try? output.close() }
        for (name, value) in ticket.fields.sorted(by: { $0.key < $1.key }) {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.escaped(name))\"\r\n\r\n\(value)\r\n".utf8))
        }
        guard let mime = UTType(filenameExtension: source.pathExtension)?.preferredMIMEType,
              mime.hasPrefix("audio/") || mime.hasPrefix("video/") else {
            throw MireloHTTPError(status: nil, code: "unsupported_asset_type", message: "Mirelo private uploads require a recognized audio or video MIME type.", retryAfterSeconds: nil, requestID: nil, retryable: false, creditRecovery: nil)
        }
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(Self.escaped(source.lastPathComponent))\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.synchronize()
        var req = URLRequest(url: ticket.uploadURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let redirectGuard = UploadRedirectGuard()
        let (_, response) = try await session.upload(
            for: req,
            fromFile: multipart,
            delegate: redirectGuard
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MireloHTTPError(status: (response as? HTTPURLResponse)?.statusCode, code: "asset_upload_failed", message: "Mirelo's private asset upload failed.", retryAfterSeconds: nil, requestID: nil, retryable: true, creditRecovery: nil)
        }
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await send(request(path: path, method: "GET"), as: type)
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        try decoder.decode(type, from: try await data(for: req))
    }

    private func data(for req: URLRequest) async throws -> Data {
        (try await response(for: req)).0
    }

    private func response(for req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw MireloHTTPError(status: nil, code: "invalid_response", message: "Mirelo returned a non-HTTP response.", retryAfterSeconds: nil, requestID: nil, retryable: true, creditRecovery: nil)
            }
            guard (200...299).contains(http.statusCode) else {
                throw Self.httpError(data: data, response: http)
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MireloHTTPError {
            throw error
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            throw MireloHTTPError(status: nil, code: "transport_interrupted", message: error.localizedDescription, retryAfterSeconds: nil, requestID: nil, retryable: true, creditRecovery: nil)
        }
    }

    private func jsonRequest(path: String, method: String, body: Data) -> URLRequest {
        var req = request(path: path, method: method)
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func request(path: String, method: String) -> URLRequest {
        request(url: url(path), method: method)
    }

    private func request(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if url.path.hasPrefix("/v3/") {
            req.setValue("2026-08-28", forHTTPHeaderField: "Mirelo-Version")
        }
        req.timeoutInterval = 60
        return req
    }

    private func url(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }

    private static func safeJobID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.")
        )
        return !value.isEmpty
            && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func httpError(data: Data, response: HTTPURLResponse) -> MireloHTTPError {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let body = (root?["error"] as? [String: Any]) ?? root
        let code = body?["code"] as? String ?? "http_\(response.statusCode)"
        let message = body?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        let requestID = body?["request_id"] as? String ?? response.value(forHTTPHeaderField: "Mirelo-Request-ID")
        let retryable = body?["retryable"] as? Bool
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        let recoverySource: Any?
        if let nested = body?["credit_recovery"] {
            recoverySource = nested
        } else if body?["credits_required"] != nil {
            recoverySource = body
        } else {
            recoverySource = nil
        }
        let recovery = recoverySource.flatMap { value -> MireloCreditRecovery? in
            guard JSONSerialization.isValidJSONObject(value),
                  let bytes = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(MireloCreditRecovery.self, from: bytes)
        }
        return MireloHTTPError(status: response.statusCode, code: code, message: message, retryAfterSeconds: retryAfter, requestID: requestID, retryable: retryable, creditRecovery: recovery)
    }

    private final class UploadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
