import AVFoundation
import Foundation
import NexGenEngine
import OnnxRuntimeBindings

/// On-device chord recognition via BTC (Bi-directional Transformer for Chord recognition, ISMIR 2019,
/// MIT-licensed) exported to ONNX. Implements the engine's generic `AudioChordRecognizing` seam; the
/// musicvideo analysis phase resolves it from the registry and carries the result into
/// `analysis.chord_progression`.
///
/// Design (see docs/CHORD_MODEL.md): the fidelity-critical CQT front-end is baked INTO the exported
/// ONNX (nnAudio, reconciled against librosa at export time, where librosa runs) rather than
/// re-implemented in Swift. The model therefore takes a raw 10 s mono window at 22.05 kHz and returns
/// per-frame chord logits; this provider only windows the audio, runs the session, arg-maxes, and
/// hands off to the pure `ChordDecode` (which reproduces BTC's exact arg-max→merge decode). Like the
/// other neural audio providers it validates on-device: a decode/model failure returns `nil` so the
/// analysis keeps an empty — never wrong — chord progression.
struct ChordRecognizer: AudioChordRecognizing {
    private static let sr: Double = 22_050
    private static let instLenS: Double = 10.0
    private static let samplesPerWindow = 220_500          // instLenS · sr
    private static let hopLength = 2048                    // CQT hop (for trimming trailing silence)

    // Hosted as GitHub release assets (chord-model-v1), produced by scripts/export_btc_chord_onnx.py.
    // A download failure (offline) resolves to recognizeChords → nil → the analysis carries no chords
    // (pipeline unaffected), exactly like a missing model.
    private static let modelURL = "https://github.com/iret77/nexgenvideo/releases/download/chord-model-v1/btc_chord.onnx"
    private static let metaURL = "https://github.com/iret77/nexgenvideo/releases/download/chord-model-v1/btc_chord_meta.json"

    /// Model sidecar: the vocabulary + geometry the Swift side needs to turn logits into chords.
    private struct Meta: Decodable {
        let vocabulary: [String]
        let num_chords: Int
        let no_chord_label: String
    }

    func recognizeChords(_ audio: URL, stems: SeparatedStems?) throws -> [RecognizedChord]? {
        // BTC trained on full mixes, so feed the full mix — a demixed stem would be off-distribution.
        // `stems` is accepted for seam parity but deliberately unused.
        let mono = try BeatThisDetector.loadMono22k(audio)
        guard mono.count > Self.hopLength else { return nil }

        let modelPath: URL
        let meta: Meta
        do {
            modelPath = try HFModelStore.ensure(urlString: Self.modelURL, file: "btc_chord.onnx", subdir: "chord")
            let metaPath = try HFModelStore.ensure(
                urlString: Self.metaURL, file: "btc_chord_meta.json", subdir: "chord", minBytes: 1)
            meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaPath))
        } catch {
            return nil   // no model hosted / offline → keep an empty chord progression
        }
        guard meta.num_chords > 0, meta.vocabulary.count == meta.num_chords else { return nil }

        let indices: [Int]
        let framesPerWindow: Int
        do {
            (indices, framesPerWindow) = try Self.runWindowed(
                mono, modelPath: modelPath.path, numChords: meta.num_chords)
        } catch {
            return nil
        }
        guard framesPerWindow > 0 else { return nil }
        // Trim frames past the real audio (the last 10 s window is zero-padded): a CQT frame per hop.
        let validFrames = min(indices.count, Int(Double(mono.count) / Double(Self.hopLength)))
        guard validFrames > 0 else { return nil }

        let hopSeconds = Self.instLenS / Double(framesPerWindow)
        let chords = ChordDecode.segments(
            labels: Array(indices.prefix(validFrames)),
            vocabulary: meta.vocabulary,
            hopSeconds: hopSeconds,
            noChordLabel: meta.no_chord_label)
        return chords.isEmpty ? nil : chords
    }

    /// Number of 10 s windows the audio is sliced into (last one zero-padded).
    private static func windowCount(_ samples: Int) -> Int {
        max(1, (samples + samplesPerWindow - 1) / samplesPerWindow)
    }

    /// Slice the mono signal into 10 s windows (zero-padding the tail), run each through the CQT+BTC
    /// ONNX, and concatenate the per-frame arg-max chord indices. Returns the indices plus the model's
    /// frames-per-window (`timestep`), read back from the output shape rather than assumed.
    private static func runWindowed(
        _ mono: [Float], modelPath: String, numChords: Int
    ) throws -> (indices: [Int], framesPerWindow: Int) {
        let session = try OrtRuntime.session(modelPath: modelPath)
        var out: [Int] = []
        var framesPerWindow = 0
        let windows = windowCount(mono.count)
        for w in 0..<windows {
            var window = [Float](repeating: 0, count: samplesPerWindow)
            let start = w * samplesPerWindow
            let n = min(samplesPerWindow, mono.count - start)
            if n > 0 { window.replaceSubrange(0..<n, with: mono[start..<(start + n)]) }

            let inData = window.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
            let inValue = try ORTValue(
                tensorData: inData, elementType: .float,
                shape: [NSNumber(value: 1), NSNumber(value: samplesPerWindow)])
            let outputs = try session.run(
                withInputs: ["audio": inValue], outputNames: ["logits"], runOptions: nil)
            guard let logitsVal = outputs["logits"] else {
                throw NSError(domain: "ChordRecognizer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "model produced no logits output"])
            }
            let logits = try floats(logitsVal)
            let frames = logits.count / numChords
            framesPerWindow = frames
            for f in 0..<frames {
                out.append(argmax(logits, base: f * numChords, count: numChords))
            }
        }
        return (out, framesPerWindow)
    }

    private static func argmax(_ v: [Float], base: Int, count: Int) -> Int {
        var best = 0
        var bestVal = v[base]
        for i in 1..<count where v[base + i] > bestVal { bestVal = v[base + i]; best = i }
        return best
    }

    private static func floats(_ value: ORTValue) throws -> [Float] {
        try withExtendedLifetime(value) {
            let data = try value.tensorData()
            let count = data.length / MemoryLayout<Float>.stride
            let p = data.bytes.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: p, count: count))
        }
    }
}
