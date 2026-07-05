import Foundation

/// Direct client for the ElevenLabs API (api.elevenlabs.io). Used whenever the user has entered an
/// ElevenLabs key in Settings → Providers, so their EL account is billed directly instead of routing
/// through fal's hosted endpoints (which need the fal key). All generation endpoints return raw audio
/// bytes; we pin mp3_44100_128 so the bytes match the .mp3 placeholder the generation flow creates.
actor ElevenLabsClient {
    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private static let base = "https://api.elevenlabs.io/v1"
    private static let outputFormat = "mp3_44100_128"

    /// name → voice_id, fetched once from GET /v1/voices and cached for the client's lifetime.
    private var voiceIds: [String: String]?

    // MARK: - Generation

    /// POST /v1/text-to-speech/{voice_id} — body { text, model_id }, returns audio bytes.
    func textToSpeech(text: String, voiceName: String) async throws -> Data {
        let voiceId = try await resolveVoiceId(named: voiceName)
        return try await post(
            path: "text-to-speech/\(voiceId)",
            body: ["text": text, "model_id": "eleven_multilingual_v2"]
        )
    }

    /// POST /v1/sound-generation — body { text, duration_seconds? (0.5–30, nil = auto) }.
    func soundEffect(text: String, durationSeconds: Double?) async throws -> Data {
        var body: [String: Any] = ["text": text]
        if let durationSeconds {
            body["duration_seconds"] = min(30.0, max(0.5, durationSeconds))
        }
        return try await post(path: "sound-generation", body: body)
    }

    /// POST /v1/music — body { prompt, music_length_ms (3000–600000), force_instrumental }.
    func music(prompt: String, lengthMs: Int, forceInstrumental: Bool) async throws -> Data {
        try await post(path: "music", body: [
            "prompt": prompt,
            "music_length_ms": min(600_000, max(3000, lengthMs)),
            "force_instrumental": forceInstrumental,
        ])
    }

    // MARK: - Voices

    /// The catalog carries voice *names* ("Rachel"); the API wants voice_ids. GET /v1/voices lists
    /// the account's voices (premade ones included) — matched case-insensitively by name.
    private func resolveVoiceId(named name: String) async throws -> String {
        if let cached = voiceIds?[name.lowercased()] { return cached }
        let data = try await get(path: "voices")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = obj["voices"] as? [[String: Any]] else {
            throw GenerationBackendError.transport("ElevenLabs: could not parse voice list")
        }
        var mapping: [String: String] = [:]
        for voice in voices {
            if let n = voice["name"] as? String, let id = voice["voice_id"] as? String {
                mapping[n.lowercased()] = id
            }
        }
        voiceIds = mapping
        guard let id = mapping[name.lowercased()] else {
            throw GenerationBackendError.transport(
                "ElevenLabs: voice \u{201C}\(name)\u{201D} not found in your account's voice list")
        }
        return id
    }

    // MARK: - HTTP

    private func post(path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(Self.base)/\(path)?output_format=\(Self.outputFormat)") else {
            throw GenerationBackendError.transport("Invalid ElevenLabs endpoint: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func get(path: String) async throws -> Data {
        guard let url = URL(string: "\(Self.base)/\(path)") else {
            throw GenerationBackendError.transport("Invalid ElevenLabs endpoint: \(path)")
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Error bodies are JSON ({"detail": …}); surface them so failures are diagnosable.
            let detail = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw GenerationBackendError.transport("ElevenLabs HTTP \(status): \(detail)")
        }
        return data
    }
}
