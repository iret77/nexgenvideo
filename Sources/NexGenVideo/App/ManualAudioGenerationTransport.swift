import AVFoundation
import Foundation
import MCP
import NexGenEngine

actor ManualAudioGenerationTransport: MCPStatusClient {
    struct Upload: Sendable { let type: String; let bytes: Data }
    private(set) var calls: [[String: Value]] = []
    private(set) var uploads: [Upload] = []
    private let output: Data

    init(output: Data) { self.output = output }

    nonisolated static var generation: MCPProviderClient.DiscoveredTool {
        let string: Value = .object(["type": .string("string")])
        return .init(name: "generate_audio", description: "Generate audio using the isolated native acceptance transport.",
            inputSchema: .object(["type": .string("object"), "properties": .object([
                "model": string, "prompt": string, "lyrics": string,
                "duration_seconds": .object(["type": .string("integer")]),
                "instrumental": .object(["type": .string("boolean")]),
                "video_url": .object(["type": .string("string"), "format": .string("uri")])
            ]), "required": .array([.string("model"), .string("prompt"), .string("duration_seconds"), .string("instrumental")]),
                "additionalProperties": .bool(false)]),
            outputSchema: .object(["type": .string("object"), "properties": .object([
                "outputs": .object(["type": .string("array"), "items": .object([
                    "type": .string("object"), "properties": .object([
                        "blob": string, "contentType": .object(["type": .string("string"), "enum": .array([.string("audio/wav")])])
                    ]), "required": .array([.string("blob"), .string("contentType")])])
            ])]))
    }

    nonisolated static var tools: [MCPProviderClient.DiscoveredTool] {
        let string: Value = .object(["type": .string("string")])
        return [generation,
            .init(name: "media_upload", description: "Create a media upload.", inputSchema: .object([
                "properties": .object(["filename": string, "type": .object(["type": .string("string"),
                    "enum": .array([.string("image"), .string("video"), .string("audio")])]),
                    "length": .object(["type": .string("integer")]), "content_type": string]),
                "required": .array([.string("filename"), .string("type"), .string("length"), .string("content_type")])])),
            .init(name: "media_confirm", description: "Confirm uploaded media.", inputSchema: .object([
                "properties": .object(["media_id": string, "type": string]),
                "required": .array([.string("media_id"), .string("type")])]))]
    }

    nonisolated static func entries() throws -> [CatalogEntry] {
        let listing = #"""
        {"items":[
          {"id":"native-acceptance-video-sfx","name":"Acceptance video SFX","output_type":"audio","tags":["audio","sfx"],"durations":[2,4,8],"medias":[{"name":"medias","type":"video","roles":["video"]}]},
          {"id":"native-acceptance-video-music","name":"Acceptance video music","output_type":"audio","tags":["audio","music"],"durations":[2,4,8],"medias":[{"name":"medias","type":"video","roles":["video"]}]}
        ]}
        """#
        let parsed = MCPModelDiscovery.parseListing(listing)
        let entries = MCPModelDiscovery.catalogEntries(models: parsed.items, toolsByModality: [.audio: generation.name],
            toolSchemasByModality: [.audio: generation.inputSchema],
            allowsLocalMedia: MCPMediaUpload.supportsUploadContract(tools), provider: .higgsfield)
        guard entries.count == 2 else { throw GateBlocked("The isolated audio discovery contract is not executable.") }
        return entries
    }

    func discoverTools() async throws -> [MCPProviderClient.DiscoveredTool] { Self.tools }
    func disconnect() async {}

    func upload(_ url: URL, type: String) throws -> String {
        uploads.append(.init(type: type, bytes: try Data(contentsOf: url)))
        return "https://media.invalid/native-audio-input.mov"
    }

    func callTool(name: String, arguments: [String: Value]) async throws -> [String] {
        guard name == Self.generation.name else { throw GateBlocked("Unexpected isolated MCP tool: " + name) }
        calls.append(arguments)
        let data = try JSONSerialization.data(withJSONObject: ["status": "completed",
            "outputs": [["blob": output.base64EncodedString(), "contentType": "audio/wav"]]])
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return MCPProviderClient.payloadContents(.init(content: [.text(text: text, annotations: nil, _meta: nil)]))
    }

    nonisolated static func wave(seconds: Int = 2, frequency: Double = 997) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard seconds > 0, seconds <= 8, frequency.isFinite, frequency > 0, frequency < 24_000 else { throw GateBlocked("Invalid isolated audio-fixture length.") }
        let count = seconds * 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let samples = buffer.floatChannelData?[0] else {
            throw GateBlocked("The actual PCM audio fixture cannot be created.")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count { samples[index] = Float(sin(Double(index) * 2 * .pi * frequency / 48_000) * 0.15) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}
