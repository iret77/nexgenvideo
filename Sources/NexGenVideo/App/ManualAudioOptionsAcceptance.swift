import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ManualAudioOptionsAcceptance {
    static func run(editor: EditorViewModel, services: GenerationPanelServices, driver: ProductionVisualSourcesDriver,
                    window: NSWindow, output: Data) async throws {
        guard let voiceModel = services.catalog.audio.first(where: { $0.category == .tts && ($0.voices?.count ?? 0) > 1
            && services.target($0.id).provider == .fal && services.canRun($0.id) }),
              let voice = voiceModel.voices?.first(where: { $0 != voiceModel.defaultVoice }),
              let musicModel = services.catalog.audio.first(where: { $0.id == "fal-ai/elevenlabs/music" && services.canRun($0.id)
                && $0.durations == nil && $0.minSeconds <= 8 && $0.supportsDurationSelection && $0.supportsInstrumental }) else {
            throw GateBlocked("The actual Fal voice and variable-duration music catalog entries are unavailable.")
        }
        try await driver.click("media.tab.Assets", in: window, enabled: false)
        let prefix = "generation.edit."
        try await driver.wait("actual document generator after Music") { driver.state(prefix + "type.Audio", in: window) != nil }
        try await driver.click(prefix + "type.Audio", in: window, enabled: false)
        try await driver.picker(prefix + "model", title: voiceModel.displayName, expected: voiceModel.id, in: window)
        try await driver.picker(prefix + "voice", title: voice, expected: voice, in: window)
        try await driver.fill(prefix + "intent", value: "The next scene begins at dawn.", in: window)
        let spoken = try await prepare(prefix: prefix, driver: driver, window: window)
        guard spoken.payload.generationInput.voice == voice, spoken.payload.references.isEmpty,
              spoken.payload.destination.kind == "media_library" else {
            throw GateBlocked("Native voice selection did not survive into the prepared speech request.")
        }
        try MusicvideoGenerationHTTP.installAudio(endpoint: spoken.payload.target.endpoint, output: output)
        try driver.capture("native-speech-voice-review", target: window)
        try await driver.click(prefix + "approve", in: window)
        let speech = try await completed(spoken, editor: editor, driver: driver)
        let speechBytes = try submittedBytes()
        let speechBody = try decodeSubmit(speechBytes)
        guard speechBody["text"] as? String == spoken.payload.prompt, speechBody["voice"] as? String == voice,
              try FileDigest.sha256(of: speech.url) == FileDigest.sha256(of: output),
              MusicvideoGenerationHTTP.unexpectedRequests.isEmpty else {
            throw GateBlocked("The actual speech submit differs from the native voice choice or returned bytes.")
        }
        let speechArtifacts = try ManualGenerationArtifacts.save(name: "audio-speech", package: spoken,
            submit: speechBytes, output: Data(contentsOf: speech.url), directory: driver.output)
        try driver.record("native speech voice reaches actual Fal client", fields: ["packageID": spoken.id, "artifacts": speechArtifacts,
            "submitFormat": "raw-http-body", "voice": voice, "defaultVoice": voiceModel.defaultVoice ?? "", "outputSHA256": FileDigest.sha256(of: output), "scope": "Native controls and actual HTTP client with isolated responses; no live provider proof."])
        try await driver.picker(prefix + "model", title: musicModel.displayName, expected: musicModel.id, in: window)
        try await driver.fill(prefix + "intent", value: "A quiet instrumental motif with a sparse piano pulse.", in: window)
        try await driver.click(prefix + "settings", in: window)
        let settings = try await popup(containing: prefix + "duration", driver: driver)
        let duration = max(3, musicModel.minSeconds)
        try await driver.fill(prefix + "duration", value: String(duration), in: settings, requireFocusExit: true)
        guard let initialInstrumental = driver.text(prefix + "instrumental", in: settings),
              initialInstrumental == "on" || initialInstrumental == "off" else {
            throw GateBlocked("The native instrumental control has no readable state.")
        }
        if initialInstrumental == "off" { try await driver.click(prefix + "instrumental", in: settings) }
        try await driver.click(prefix + "instrumental", in: settings)
        guard driver.text(prefix + "instrumental", in: settings) == "off" else {
            throw GateBlocked("The native instrumental control did not turn off.")
        }
        try await driver.click(prefix + "instrumental", in: settings)
        guard driver.text(prefix + "instrumental", in: settings) == "on",
              driver.text(prefix + "duration", in: settings) == String(duration) else {
            throw GateBlocked("Native instrumental/duration settings did not take effect.")
        }
        try driver.pressKey(53, characters: "\u{1b}", in: settings)
        try await driver.wait("audio settings closed") { window.isKeyWindow }
        let music = try await prepare(prefix: prefix, driver: driver, window: window)
        guard music.payload.generationInput.duration == duration, music.payload.generationInput.instrumental == true else {
            throw GateBlocked("The range-based music duration or instrumental choice was dropped before review.")
        }
        let musicOutput = try await Task.detached { try ManualAudioGenerationTransport.wave(seconds: duration) }.value
        try MusicvideoGenerationHTTP.installAudio(endpoint: music.payload.target.endpoint, output: musicOutput)
        try driver.capture("native-instrumental-duration-review", target: window)
        try await driver.click(prefix + "approve", in: window)
        let result = try await completed(music, editor: editor, driver: driver)
        let musicBytes = try submittedBytes()
        let musicBody = try decodeSubmit(musicBytes)
        guard musicBody["prompt"] as? String == music.payload.prompt,
              musicBody["music_length_ms"] as? Int == duration * 1000, musicBody["force_instrumental"] as? Bool == true,
              try FileDigest.sha256(of: result.url) == FileDigest.sha256(of: musicOutput),
              MusicvideoGenerationHTTP.unexpectedRequests.isEmpty else {
            throw GateBlocked("The actual music request lost its native duration or instrumental setting.")
        }
        let actualDuration = try await AVURLAsset(url: result.url).load(.duration).seconds
        guard abs(actualDuration - Double(duration)) < 0.02 else { throw GateBlocked("The actual music output has the wrong decoded duration.") }
        let musicArtifacts = try ManualGenerationArtifacts.save(name: "audio-instrumental", package: music,
            submit: musicBytes, output: Data(contentsOf: result.url), directory: driver.output)
        try driver.record("native range duration and instrumental reach actual Fal client", fields: ["packageID": music.id, "artifacts": musicArtifacts,
            "submitFormat": "raw-http-body", "requestedDurationSeconds": duration, "instrumental": true, "initialInstrumental": initialInstrumental,
            "decodedFixtureDurationSeconds": actualDuration,
            "scope": "Native duration/instrumental controls, actual HTTP adapter and decoded simulator output; no live provider compliance proof."])
    }

    private static func prepare(prefix: String, driver: ProductionVisualSourcesDriver, window: NSWindow) async throws -> GenerationPackageV1 {
        try await driver.click(prefix + "review", in: window)
        try await driver.wait("actual native audio options package") { driver.state(prefix + "approve", in: window) == true }
        try await driver.click(prefix + "package.details", in: window)
        try await driver.click(prefix + "package.copy-package", in: window)
        guard let text = NSPasteboard.general.string(forType: .string) else { throw GateBlocked("The actual audio-options package was not copied.") }
        return try JSONDecoder().decode(GenerationPackageV1.self, from: Data(text.utf8))
    }

    private static func completed(_ package: GenerationPackageV1, editor: EditorViewModel, driver: ProductionVisualSourcesDriver) async throws -> MediaAsset {
        try await driver.wait("real downloaded native audio", seconds: 60) {
            editor.mediaAssets.contains { $0.generationInput?.generationPackageID == package.id && $0.generationStatus == .none }
        }
        guard let asset = editor.mediaAssets.first(where: { $0.generationInput?.generationPackageID == package.id && $0.generationStatus == .none }),
              asset.type == .audio else { throw GateBlocked("No completed audio file matches the reviewed request.") }
        return asset
    }

    private static func submittedBytes() throws -> Data {
        let posts = MusicvideoGenerationHTTP.requests.filter { $0.method == "POST" && $0.url.hasPrefix("https://queue.fal.run/") }
        guard posts.count == 1, let post = posts.first else {
            throw GateBlocked("The isolated transport did not receive exactly one native audio submit.")
        }
        return post.body
    }

    private static func decodeSubmit(_ bytes: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw GateBlocked("The isolated audio submit is not a JSON object.")
        }
        return object
    }

    private static func popup(containing identifier: String, driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        try await driver.wait("actual native audio settings") {
            NSApp.windows.contains { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: $0) != nil }
        }
        guard let popup = NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow
            && WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: $0) != nil }) else {
            throw GateBlocked("The audio settings did not take native keyboard focus.")
        }
        return popup
    }
}
