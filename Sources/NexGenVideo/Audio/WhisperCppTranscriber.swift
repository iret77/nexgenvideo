import AVFoundation
import Foundation
import NexGenEngine
import whisper

/// On-device speech recognition via vendored whisper.cpp (Metal-accelerated). Implements the engine's
/// generic `AudioTranscribing` seam; the musicvideo pack resolves it to align known lyrics against the
/// sung vocals. whisper.cpp is fully synchronous, so this is a plain blocking call — it's invoked from
/// the analysis phase runner, which already runs off the main actor.
struct WhisperCppTranscriber: ContextualAudioTranscribing, AudioLyricsAligning {
    var model: String = WhisperModelStore.defaultModel

    private enum TimingStrategy: Equatable {
        case decoder
        case attentionDTW
    }

    struct DecodingConfiguration: Equatable {
        let language: String
        let detectLanguageOnly: Bool
    }

    enum TranscribeError: LocalizedError {
        case audioLoadFailed(String)
        case modelInitFailed(String)
        case inferenceFailed(Int)
        var errorDescription: String? {
            switch self {
            case .audioLoadFailed(let m): return "Couldn't read the audio for transcription: \(m)"
            case .modelInitFailed(let m): return "Couldn't load the speech model: \(m)"
            case .inferenceFailed(let c): return "Speech recognition failed (code \(c))."
            }
        }
    }

    func transcribe(_ audio: URL, language: String) throws -> [TranscribedWord] {
        try performTranscription(
            audio,
            language: language,
            context: nil,
            timing: .decoder
        )
    }

    func transcribe(
        _ audio: URL,
        language: String,
        context: String
    ) throws -> [TranscribedWord] {
        try performTranscription(
            audio,
            language: language,
            context: context,
            timing: .decoder
        )
    }

    func alignLyrics(
        _ audio: URL,
        language: String,
        lyrics: String
    ) throws -> [TranscribedWord] {
        try performTranscription(
            audio,
            language: language,
            context: lyrics,
            timing: .attentionDTW
        )
    }

    private func performTranscription(
        _ audio: URL,
        language: String,
        context: String?,
        timing: TimingStrategy
    ) throws -> [TranscribedWord] {
        let samples = try Self.loadPCM16kMono(audio)
        guard !samples.isEmpty else { return [] }
        let modelPath = try WhisperModelStore.ensureModel(model)

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        if timing == .attentionDTW {
            cparams.flash_attn = false
            cparams.dtw_token_timestamps = true
            cparams.dtw_aheads_preset = Self.alignmentHeadsPreset(for: model)
        }
        guard let ctx = modelPath.path.withCString({ whisper_init_from_file_with_params($0, cparams) }) else {
            throw TranscribeError.modelInitFailed(modelPath.lastPathComponent)
        }
        defer { whisper_free(ctx) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        let decoding = Self.decodingConfiguration(language: language)
        params.detect_language = decoding.detectLanguageOnly
        params.token_timestamps = true   // fills whisper_token_data.t0/t1 per token
        params.no_context = false
        params.suppress_blank = true
        params.split_on_word = true
        params.max_len = 1
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        let lang = strdup(decoding.language)
        defer { free(lang) }
        params.language = lang.map { UnsafePointer($0) }

        let prompt = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialPrompt = prompt.flatMap { $0.isEmpty ? nil : strdup($0) }
        defer { free(initialPrompt) }
        params.initial_prompt = initialPrompt.map { UnsafePointer($0) }
        params.carry_initial_prompt = timing == .attentionDTW

        let rc = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else { throw TranscribeError.inferenceFailed(Int(rc)) }

        return Self.extractWords(
            ctx,
            noSpeechThreshold: Double(params.no_speech_thold),
            preferDTW: timing == .attentionDTW
        )
    }

    static func alignmentHeadsPreset(
        for model: String
    ) -> whisper_alignment_heads_preset {
        switch model {
        case "medium": return WHISPER_AHEADS_MEDIUM
        case "small": return WHISPER_AHEADS_SMALL
        default: return WHISPER_AHEADS_LARGE_V3_TURBO
        }
    }

    static func decodingConfiguration(language: String) -> DecodingConfiguration {
        DecodingConfiguration(
            language: language.isEmpty || language == "auto" ? "auto" : language,
            detectLanguageOnly: false
        )
    }

    /// Reconstruct words from whisper's subword tokens: whisper prefixes a new word's first token with
    /// a space, so a space-prefixed token (or the very first) opens a new word. Times come from the
    /// token-level `t0`/`t1` (centiseconds → seconds); confidence is the mean token probability.
    private static func extractWords(
        _ ctx: OpaquePointer,
        noSpeechThreshold: Double,
        preferDTW: Bool
    ) -> [TranscribedWord] {
        var words: [TranscribedWord] = []
        let eot = whisper_token_eot(ctx)
        var cur: (
            text: String,
            start: Double,
            end: Double,
            dtwStart: Double?,
            dtwEnd: Double?,
            pSum: Double,
            pCount: Int
        )?

        func flush() {
            defer { cur = nil }
            guard let c = cur else { return }
            let text = c.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            guard let timing = Self.resolvedTiming(
                decoderStart: c.start,
                decoderEnd: c.end,
                dtwStart: c.dtwStart,
                dtwEnd: c.dtwEnd,
                preferDTW: preferDTW
            ) else { return }
            words.append(TranscribedWord(
                text: text,
                start: timing.start,
                end: max(timing.end, timing.start),
                confidence: c.pCount > 0 ? c.pSum / Double(c.pCount) : nil))
        }

        for segment in 0..<whisper_full_n_segments(ctx) {
            flush()  // a word never spans two segments — close the previous segment's last word
            let noSpeechProbability = Double(
                whisper_full_get_segment_no_speech_prob(ctx, segment)
            )
            guard Self.isAcousticallySupportedSegment(
                noSpeechProbability: noSpeechProbability,
                threshold: noSpeechThreshold
            ) else { continue }
            for token in 0..<whisper_full_n_tokens(ctx, segment) {
                if whisper_full_get_token_id(ctx, segment, token) >= eot { continue }  // special/timestamp token
                guard let cstr = whisper_full_get_token_text(ctx, segment, token) else { continue }
                let piece = String(cString: cstr)
                if piece.isEmpty { continue }
                let data = whisper_full_get_token_data(ctx, segment, token)
                let t0 = Double(data.t0) / 100.0
                let t1 = Double(data.t1) / 100.0
                let dtw = data.t_dtw >= 0 ? Double(data.t_dtw) / 100.0 : nil
                let p = Double(data.p)
                if piece.hasPrefix(" ") || cur == nil {
                    flush()
                    cur = (
                        text: piece,
                        start: t0,
                        end: t1,
                        dtwStart: dtw,
                        dtwEnd: dtw,
                        pSum: p,
                        pCount: 1
                    )
                } else {
                    cur?.text += piece
                    cur?.end = t1
                    if let dtw {
                        if cur?.dtwStart == nil { cur?.dtwStart = dtw }
                        cur?.dtwEnd = dtw
                    }
                    cur?.pSum += p
                    cur?.pCount += 1
                }
            }
        }
        flush()
        return preferDTW ? Self.finalizedDTWSpans(words) : words
    }

    static func resolvedTiming(
        decoderStart: Double,
        decoderEnd: Double,
        dtwStart: Double?,
        dtwEnd: Double?,
        preferDTW: Bool
    ) -> (start: Double, end: Double)? {
        if preferDTW {
            guard let dtwStart, let dtwEnd else { return nil }
            return (dtwStart, max(dtwStart, max(dtwEnd, decoderEnd)))
        }
        return (decoderStart, decoderEnd)
    }

    static func finalizedDTWSpans(_ words: [TranscribedWord]) -> [TranscribedWord] {
        guard !words.isEmpty else { return [] }
        var result = words
        if result.count > 1 {
            for index in 0..<(result.count - 1) {
                let nextStart = result[index + 1].start
                if nextStart > result[index].start {
                    result[index].end = nextStart
                }
            }
        }
        return result.filter { $0.end > $0.start }
    }

    static func isAcousticallySupportedSegment(
        noSpeechProbability: Double,
        threshold: Double
    ) -> Bool {
        noSpeechProbability.isFinite
            && threshold.isFinite
            && noSpeechProbability < threshold
    }

    /// Decode an audio file to mono Float32 at whisper's required 16 kHz (channel-averaged downmix +
    /// resample). Whole-file, single-shot conversion — matching the analysis decoder's approach.
    static func loadPCM16kMono(_ url: URL) throws -> [Float] {
        let target = 16_000.0
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw TranscribeError.audioLoadFailed("\(url.lastPathComponent) (\(error.localizedDescription))")
        }
        let source = file.processingFormat
        let frames = file.length
        guard frames > 0 else { return [] }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false) else {
            throw TranscribeError.audioLoadFailed("could not build 16 kHz format")
        }

        if source.channelCount == 1, source.sampleRate == target, source.commonFormat == .pcmFormatFloat32 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)) else {
                throw TranscribeError.audioLoadFailed("could not allocate read buffer")
            }
            do { try file.read(into: buf) } catch {
                throw TranscribeError.audioLoadFailed(error.localizedDescription)
            }
            guard let ch = buf.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        }

        guard let converter = AVAudioConverter(from: source, to: targetFormat) else {
            throw TranscribeError.audioLoadFailed("no converter to 16 kHz mono")
        }
        converter.downmix = true
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)) else {
            throw TranscribeError.audioLoadFailed("could not allocate read buffer")
        }
        do { try file.read(into: readBuffer) } catch {
            throw TranscribeError.audioLoadFailed("\(url.lastPathComponent) (\(error.localizedDescription))")
        }
        let ratio = target / source.sampleRate
        let outCap = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else {
            throw TranscribeError.audioLoadFailed("could not allocate output buffer")
        }
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true; outStatus.pointee = .haveData; return readBuffer
        }
        if let convError { throw TranscribeError.audioLoadFailed(convError.localizedDescription) }
        guard status != .error, let ch = outBuffer.floatChannelData?[0] else {
            throw TranscribeError.audioLoadFailed("converter returned an error")
        }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuffer.frameLength)))
    }
}
