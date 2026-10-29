import Foundation

struct AudioGenerationParams: Encodable, Sendable {
    let prompt: String
    let voice: String?
    let lyrics: String?
    let styleInstructions: String?
    let instrumental: Bool
    let durationSeconds: Int?
    var videoURL: String? = nil

    enum CodingKeys: String, CodingKey {
        case kind, prompt, voice, lyrics, styleInstructions, instrumental, durationSeconds, videoURL
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("audio", forKey: .kind)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(voice, forKey: .voice)
        try c.encodeIfPresent(lyrics, forKey: .lyrics)
        try c.encodeIfPresent(styleInstructions, forKey: .styleInstructions)
        try c.encode(instrumental, forKey: .instrumental)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(videoURL, forKey: .videoURL)
    }
}

struct AudioModelConfig: Identifiable, Sendable {
    enum Category: Sendable, Hashable, CaseIterable {
        case tts
        case music
        case sfx

        var label: String {
            switch self {
            case .tts: "Speech"
            case .music: "Music"
            case .sfx: "Sound Effects"
            }
        }
    }

    enum Input: String, Sendable, Hashable {
        case text
        case video
    }

    enum Pricing: Sendable {
        case perThousandChars(Double)
        case perSecond(Double)
        case flat(Double)
        case unknown
    }

    @MainActor
    static var allModels: [AudioModelConfig] { ModelCatalog.shared.audio }

    let entry: CatalogEntry
    let caps: AudioCaps

    var id: String { entry.id }
    var displayName: String { entry.displayName }

    var category: Category {
        switch caps.category {
        case "music": .music
        case "sfx": .sfx
        default: .tts
        }
    }
    var voices: [String]? { caps.voices }
    var defaultVoice: String? { caps.defaultVoice }
    var supportsLyrics: Bool { caps.supportsLyrics }
    var supportsInstrumental: Bool { caps.supportsInstrumental }
    var supportsStyleInstructions: Bool { caps.supportsStyleInstructions }
    var durations: [Int]? { caps.durations }
    var supportsDurationSelection: Bool { durations != nil || caps.minSeconds != nil || caps.maxSeconds != nil }
    var minPromptLength: Int { caps.minPromptLength }

    var inputs: [Input] { (caps.inputs ?? ["text"]).compactMap(Input.init(rawValue:)) }
    var promptLabel: String { caps.promptLabel ?? "Describe the sound" }
    var minSeconds: Int { caps.minSeconds ?? 1 }
    var maxSeconds: Int { caps.maxSeconds ?? 900 }

    func validate(spanSeconds: Double) -> String? {
        guard spanSeconds.isFinite, spanSeconds > 0 else { return "Choose a valid audio duration." }
        let selected = String(format: "%.2f", spanSeconds)
        if spanSeconds < Double(minSeconds) {
            return "\(displayName) needs at least \(minSeconds)s (selection is \(selected)s)."
        }
        if spanSeconds > Double(maxSeconds) {
            return "\(displayName) accepts at most \(maxSeconds)s (selection is \(selected)s)."
        }
        return nil
    }

    var pricing: Pricing {
        switch entry.audioPricing {
        case .perThousandChars(let rate): return .perThousandChars(rate)
        case .perSecond(let rate): return .perSecond(rate)
        case .flat(let price): return .flat(price)
        case .none: return .unknown
        }
    }

    func validate(params: AudioGenerationParams) -> String? {
        let promptLen = params.prompt.trimmingCharacters(in: .whitespaces).count
        if promptLen < minPromptLength {
            return "\(displayName) requires prompt ≥ \(minPromptLength) characters (got \(promptLen))."
        }
        if let allowed = voices, let v = params.voice, !v.isEmpty, !allowed.contains(v) {
            let shown = Array(allowed.prefix(6)) + (allowed.count > 6 ? ["…"] : [])
            return unsupportedValue(model: displayName, field: "voice", value: v, allowed: shown)
        }
        if params.lyrics?.isEmpty == false, !supportsLyrics { return "\(displayName) does not accept lyrics." }
        if params.styleInstructions?.isEmpty == false, !supportsStyleInstructions { return "\(displayName) does not accept style instructions." }
        if params.instrumental, !supportsInstrumental { return "\(displayName) does not offer an instrumental setting." }
        if params.videoURL != nil, !inputs.contains(.video) { return "\(displayName) does not accept a source video." }
        if let duration = params.durationSeconds, supportsDurationSelection,
           let error = validate(spanSeconds: Double(duration)) { return error }
        if let allowed = durations, let d = params.durationSeconds, !allowed.contains(d) {
            return unsupportedValue(
                model: displayName, field: "duration",
                value: "\(d)s", allowed: allowed.map { "\($0)s" }
            )
        }
        return nil
    }
}
