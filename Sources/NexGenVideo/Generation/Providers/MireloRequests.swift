import Foundation

enum MireloRequestBuilder {
    static func textToSFX(
        model: String,
        prompt: String,
        durationMS: Int,
        numVariants: Int,
        loop: Bool,
        outputFormat: String
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "duration_ms": durationMS,
            "num_variants": numVariants,
            "input": ["prompt": prompt],
            "output": ["format": outputFormat],
        ]
        if loop { body["controls"] = ["loop": true] }
        return try encode(body)
    }

    static func videoToSFX(
        model: String,
        assetID: String,
        prompt: String?,
        durationMS: Int,
        startOffsetMS: Int,
        numVariants: Int,
        preserveSpeech: Bool,
        outputFormat: String
    ) throws -> Data {
        var input: [String: Any] = [
            "video": ["type": "asset", "id": assetID],
        ]
        if let prompt, !prompt.isEmpty { input["prompt"] = prompt }
        var body: [String: Any] = [
            "model": model,
            "duration_ms": durationMS,
            "num_variants": numVariants,
            "input": input,
            "output": ["format": outputFormat],
        ]
        if startOffsetMS > 0 { body["start_offset_ms"] = startOffsetMS }
        if preserveSpeech { body["controls"] = ["preserve_speech": true] }
        return try encode(body)
    }

    static func extend(
        model: String,
        audioAssetID: String,
        videoAssetID: String?,
        prompt: String?,
        appendDurationMS: Int,
        startOffsetMS: Int,
        numVariants: Int,
        loop: Bool,
        outputFormat: String
    ) throws -> Data {
        var input: [String: Any] = [
            "audio": ["type": "asset", "id": audioAssetID],
        ]
        if let videoAssetID {
            input["video"] = ["type": "asset", "id": videoAssetID]
        }
        if let prompt, !prompt.isEmpty { input["prompt"] = prompt }
        var body: [String: Any] = [
            "model": model,
            "append_duration_ms": appendDurationMS,
            "num_variants": numVariants,
            "input": input,
            "output": ["format": outputFormat],
        ]
        if startOffsetMS > 0 { body["start_offset_ms"] = startOffsetMS }
        if loop { body["controls"] = ["loop": true] }
        return try encode(body)
    }

    static func inpaint(
        model: String,
        audioAssetID: String,
        videoAssetID: String?,
        prompt: String?,
        regionStartMS: Int,
        regionEndMS: Int,
        numVariants: Int,
        outputFormat: String
    ) throws -> Data {
        var input: [String: Any] = [
            "audio": ["type": "asset", "id": audioAssetID],
        ]
        if let videoAssetID {
            input["video"] = ["type": "asset", "id": videoAssetID]
        }
        if let prompt, !prompt.isEmpty { input["prompt"] = prompt }
        return try encode([
            "model": model,
            "region": ["start_ms": regionStartMS, "end_ms": regionEndMS],
            "num_variants": numVariants,
            "input": input,
            "output": ["format": outputFormat],
        ])
    }

    static func audioToMIDI(
        assetID: String,
        timing: String,
        subdivision: String?,
        timeSignatureNumerator: Int?,
        timeSignatureDenominator: Int?,
        fixedTempo: Bool,
        fixedTempoBPM: Double?,
        optimizeMusicXML: Bool,
        scorePDFs: Bool,
        pageSize: String,
        instruments: [String]?
    ) throws -> Data {
        let timings: Set<String> = ["performance", "quantized"]
        let subdivisions: Set<String> = [
            "automatic", "straight_sixteenths", "eighth_triplets",
            "sixteenth_triplets", "swing_eighths",
        ]
        let pages: Set<String> = ["a4", "letter"]
        guard timings.contains(timing),
              subdivision.map({ subdivisions.contains($0) }) ?? true,
              pages.contains(pageSize) else {
            throw GenerationRequestError.optionsInvalid(
                "The Audio-to-MIDI timing, subdivision, or page size is unsupported."
            )
        }
        if let fixedTempoBPM, !(30.0...300.0).contains(fixedTempoBPM) {
            throw GenerationRequestError.optionsInvalid(
                "Audio-to-MIDI fixed tempo must be between 30 and 300 BPM."
            )
        }
        if let instruments {
            guard instruments.count <= supportedInstruments.count,
                  Set(instruments).count == instruments.count,
                  instruments.allSatisfy({ supportedInstruments.contains($0) }) else {
                throw GenerationRequestError.optionsInvalid(
                    "Audio-to-MIDI instruments must be a unique complete list from the documented instrument set."
                )
            }
        }
        var body: [String: Any] = [
            "audio": ["type": "asset", "asset_id": assetID],
            "timing": timing,
            "optimize_musicxml": optimizeMusicXML || scorePDFs,
            "score_pdfs": scorePDFs,
            "page_size": pageSize,
        ]
        if let subdivision { body["subdivision"] = subdivision }
        if (timeSignatureNumerator == nil) != (timeSignatureDenominator == nil) {
            throw GenerationRequestError.optionsInvalid(
                "Set both Audio-to-MIDI time-signature values or omit both."
            )
        }
        if let numerator = timeSignatureNumerator,
           let denominator = timeSignatureDenominator {
            let valid = (denominator == 4
                && [2, 3, 4, 5, 6, 7, 9, 12].contains(numerator))
                || (denominator == 8 && [6, 9, 12].contains(numerator))
            guard valid else {
                throw GenerationRequestError.optionsInvalid(
                    "Mirelo accepts 2–7, 9, or 12 over 4, and 6, 9, or 12 over 8."
                )
            }
            body["time_signature"] = [
                "numerator": numerator,
                "denominator": denominator,
            ]
        }
        if fixedTempo || fixedTempoBPM != nil {
            var tempo: [String: Any] = ["mode": "fixed"]
            if let fixedTempoBPM { tempo["bpm"] = fixedTempoBPM }
            body["tempo"] = tempo
        }
        if let instruments, !instruments.isEmpty { body["instruments"] = instruments }
        return try encode(body)
    }

    static func validate(
        operation: MireloOperation,
        model: MireloModel,
        durationMS: Int?,
        appendDurationMS: Int?,
        regionStartMS: Int?,
        regionEndMS: Int?,
        numVariants: Int,
        prompt: String?,
        loop: Bool,
        preserveSpeech: Bool
    ) throws {
        guard MireloCatalogDiscovery.supportedOperationIDs(model).contains(
            operation.rawValue
        ), let limits = model.operations[operation.rawValue] else {
            throw GenerationRequestError.optionsInvalid(
                "Mirelo model '\(model.id)' does not offer \(operation.rawValue) for this account."
            )
        }
        switch operation {
        case .textToSFX, .videoToSFX:
            guard durationMS != nil else {
                throw GenerationRequestError.optionsInvalid("durationMs is required.")
            }
        case .extend:
            guard appendDurationMS != nil else {
                throw GenerationRequestError.optionsInvalid("appendDurationMs is required.")
            }
        case .inpaint:
            guard regionStartMS != nil, regionEndMS != nil else {
                throw GenerationRequestError.optionsInvalid(
                    "regionStartMs and regionEndMs are required."
                )
            }
        case .audioToMIDI:
            throw GenerationRequestError.optionsInvalid(
                "Audio-to-MIDI uses its dedicated request contract."
            )
        }
        if let prompt, prompt.unicodeScalars.count > model.maxPromptChars {
            throw GenerationRequestError.optionsInvalid(
                "Mirelo model '\(model.id)' accepts at most \(model.maxPromptChars) prompt characters."
            )
        }
        if let range = limits.numVariants {
            try require(numVariants, in: range, label: "numVariants")
        }
        if let durationMS, let range = limits.durationMs {
            try require(
                durationMS,
                minimum: loop ? range.minWithLoop ?? range.min : range.min,
                maximum: preserveSpeech
                    ? range.maxWithPreserveSpeech ?? range.max
                    : loop ? range.maxWithLoop ?? range.max : range.max,
                label: "durationMs"
            )
        }
        if let appendDurationMS, let range = limits.appendDurationMs {
            try require(
                appendDurationMS,
                minimum: loop ? range.minWithLoop ?? range.min : range.min,
                maximum: range.max,
                label: "appendDurationMs"
            )
        }
        if loop, limits.controls?.contains("loop") != true {
            throw GenerationRequestError.optionsInvalid(
                "Mirelo model '\(model.id)' does not offer loop for \(operation.rawValue)."
            )
        }
        if preserveSpeech, limits.controls?.contains("preserve_speech") != true {
            throw GenerationRequestError.optionsInvalid(
                "Mirelo model '\(model.id)' does not offer preserve_speech for \(operation.rawValue)."
            )
        }
        if let start = regionStartMS, let range = limits.regionStartMs,
           let minimum = range.min, start < minimum {
            throw GenerationRequestError.optionsInvalid(
                "Mirelo requires regionStartMs ≥ \(minimum)."
            )
        }
        if let start = regionStartMS, let end = regionEndMS {
            guard end > start else {
                throw GenerationRequestError.optionsInvalid(
                    "regionEndMs must be greater than regionStartMs."
                )
            }
            if let range = limits.regionWidthMs {
                try require(end - start, in: range, label: "region width")
            }
        }
    }

    private static func require(
        _ value: Int,
        in range: MireloRange,
        label: String
    ) throws {
        try require(value, minimum: range.min, maximum: range.max, label: label)
    }

    private static func require(
        _ value: Int,
        minimum: Int?,
        maximum: Int?,
        label: String
    ) throws {
        if let minimum, value < minimum {
            throw GenerationRequestError.optionsInvalid(
                "Mirelo requires \(label) ≥ \(minimum)."
            )
        }
        if let maximum, value > maximum {
            throw GenerationRequestError.optionsInvalid(
                "Mirelo requires \(label) ≤ \(maximum)."
            )
        }
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw GenerationRequestError.optionsInvalid(
                "The Mirelo request contains invalid JSON values."
            )
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static let supportedInstruments: Set<String> = [
        "acoustic_piano", "electric_piano", "chromatic_percussion", "organ",
        "acoustic_guitar", "clean_electric_guitar", "distorted_electric_guitar",
        "acoustic_bass", "electric_bass", "violin", "viola", "cello", "contrabass",
        "orchestral_harp", "timpani", "string_ensemble", "synth_strings", "voice",
        "orchestra_hit", "trumpet", "trombone", "tuba", "french_horn", "brass_section",
        "soprano_and_alto_sax", "tenor_sax", "baritone_sax", "oboe", "english_horn",
        "bassoon", "clarinet", "flutes", "synth_lead", "synth_pad", "drums",
    ]
}

struct MireloResultDescriptor: Sendable, Equatable {
    let kind: MireloArtifact.Kind
    let remoteURL: URL?
    let embeddedData: Data?
    let filename: String
    let sourceURLExpiresAt: String?
    let expectedSHA256: String?
}

enum MireloResultParser {
    static func descriptors(
        operation: MireloOperation,
        terminalResponse: Data
    ) throws -> [MireloResultDescriptor] {
        guard let root = try JSONSerialization.jsonObject(
            with: terminalResponse
        ) as? [String: Any] else {
            throw GenerationRequestError.storage("Mirelo returned invalid result JSON.")
        }
        if operation == .audioToMIDI {
            return try midiDescriptors(root)
        }
        return try audioDescriptors(root)
    }

    private static func audioDescriptors(
        _ root: [String: Any]
    ) throws -> [MireloResultDescriptor] {
        guard let result = root["result"] as? [String: Any] else {
            throw GenerationRequestError.storage(
                "Mirelo completed without an audio result."
            )
        }
        var outputs: [[String: Any]] = []
        if let output = result["output"] as? [String: Any] { outputs.append(output) }
        outputs += result["outputs"] as? [[String: Any]] ?? []
        var descriptors: [MireloResultDescriptor] = []
        for output in outputs {
            let outputIndex = output["index"] as? Int ?? descriptors.count
            for variant in output["variants"] as? [[String: Any]] ?? []
            where (variant["status"] as? String) == "succeeded" {
                guard let files = variant["files"] as? [String: Any],
                      let audio = files["audio"] as? [String: Any],
                      let urlString = audio["url"] as? String,
                      let url = URL(string: urlString) else { continue }
                let variantIndex = variant["index"] as? Int ?? descriptors.count
                let format = audio["format"] as? String ?? "wav"
                descriptors.append(MireloResultDescriptor(
                    kind: .audio,
                    remoteURL: url,
                    embeddedData: nil,
                    filename: "output-\(outputIndex)-\(variantIndex).\(extensionForAudioFormat(format))",
                    sourceURLExpiresAt: audio["url_expires_at"] as? String,
                    expectedSHA256: nil
                ))
            }
        }
        guard !descriptors.isEmpty else {
            throw GenerationRequestError.storage(
                "Mirelo completed without a usable audio URL."
            )
        }
        return descriptors
    }

    private static func midiDescriptors(
        _ root: [String: Any]
    ) throws -> [MireloResultDescriptor] {
        guard let result = root["result"] as? [String: Any],
              let midiString = result["midi_url"] as? String,
              let midiURL = URL(string: midiString) else {
            throw GenerationRequestError.storage(
                "Mirelo completed without the required MIDI result."
            )
        }
        var descriptors = [MireloResultDescriptor(
            kind: .midi,
            remoteURL: midiURL,
            embeddedData: nil,
            filename: "transcription.mid",
            sourceURLExpiresAt: nil,
            expectedSHA256: nil
        )]
        let noteData = try JSONSerialization.data(
            withJSONObject: result,
            options: [.sortedKeys]
        )
        descriptors.append(MireloResultDescriptor(
            kind: .noteJSON,
            remoteURL: nil,
            embeddedData: noteData,
            filename: "notes.json",
            sourceURLExpiresAt: nil,
            expectedSHA256: nil
        ))
        if let value = result["musicxml_url"] as? String,
           let url = URL(string: value) {
            descriptors.append(.init(
                kind: .musicXML,
                remoteURL: url,
                embeddedData: nil,
                filename: "score.musicxml",
                sourceURLExpiresAt: nil,
                expectedSHA256: nil
            ))
        }
        if let value = result["score_bundle_url"] as? String,
           let url = URL(string: value) {
            descriptors.append(.init(
                kind: .scoreBundle,
                remoteURL: url,
                embeddedData: nil,
                filename: "scores.zip",
                sourceURLExpiresAt: nil,
                expectedSHA256: nil
            ))
        }
        if let value = result["score_manifest_url"] as? String,
           let url = URL(string: value) {
            descriptors.append(.init(
                kind: .scoreManifest,
                remoteURL: url,
                embeddedData: nil,
                filename: "score-manifest.json",
                sourceURLExpiresAt: nil,
                expectedSHA256: nil
            ))
        }
        for (index, pdf) in (result["score_pdfs"] as? [[String: Any]] ?? []).enumerated() {
            guard let value = pdf["url"] as? String,
                  let url = URL(string: value) else { continue }
            let supplied = (pdf["filename"] as? String)?.components(
                separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. ")).inverted
            ).joined(separator: "_")
            let filename = supplied.flatMap { value -> String? in
                guard !value.isEmpty, value != ".", value != "..",
                      URL(fileURLWithPath: value).pathExtension.lowercased() == "pdf" else {
                    return nil
                }
                return value
            } ?? "score-\(index + 1).pdf"
            descriptors.append(.init(
                kind: .scorePDF,
                remoteURL: url,
                embeddedData: nil,
                filename: filename,
                sourceURLExpiresAt: nil,
                expectedSHA256: pdf["sha256"] as? String
            ))
        }
        return descriptors
    }

    private static func extensionForAudioFormat(_ format: String) -> String {
        if format.hasPrefix("mp3") { return "mp3" }
        if format.hasPrefix("m4a") { return "m4a" }
        return format == "flac" ? "flac" : "wav"
    }
}
