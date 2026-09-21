import Foundation

extension ToolExecutor {
    private static let syncAudioAllowedKeys: Set<String> = [
        "referenceClipId", "targetClipId", "targetClipIds", "mode", "searchWindowSeconds", "minConfidence",
    ]

    func syncAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.syncAudioAllowedKeys, path: "sync_audio")

        let referenceClipId = try args.requireString("referenceClipId")
        var targets = args.stringArray("targetClipIds")
        if let single = args.string("targetClipId") { targets.append(single) }
        guard !targets.isEmpty else {
            throw ToolError("sync_audio: provide targetClipId or targetClipIds.")
        }

        let searchWindow = args.double("searchWindowSeconds")
            ?? EditorViewModel.SyncDefaults.searchWindowSeconds
        guard searchWindow.isFinite,
              searchWindow > 0,
              searchWindow <= EditorViewModel.SyncDefaults.maxSearchWindowSeconds else {
            throw ToolError("sync_audio: searchWindowSeconds must be greater than 0 and at most 3600.")
        }
        let minConfidence = args.double("minConfidence")
            ?? EditorViewModel.SyncDefaults.minConfidence
        guard minConfidence.isFinite, (0...1).contains(minConfidence) else {
            throw ToolError("sync_audio: minConfidence must be between 0 and 1.")
        }
        let modeValue = args.string("mode") ?? EditorViewModel.SyncMode.auto.rawValue
        guard let mode = EditorViewModel.SyncMode(rawValue: modeValue) else {
            throw ToolError("sync_audio: mode must be auto, audio, or timecode.")
        }

        let report = await editor.syncClips(
            referenceClipId: referenceClipId,
            targetClipIds: targets,
            mode: mode,
            searchWindowSeconds: searchWindow,
            minConfidence: minConfidence
        )
        func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        var payload: [String: Any] = [
            "referenceClipId": referenceClipId,
            "mode": mode.rawValue,
            "applied": !report.synced.isEmpty,
            "shiftedFrames": report.shiftedFrames,
            "synced": report.synced.map { result -> [String: Any] in
                var item: [String: Any] = [
                    "clipId": result.clipId,
                    "method": result.method.rawValue,
                    "offsetFrames": result.offsetFrames,
                    "confidence": rounded(result.confidence),
                    "reason": result.reason,
                ]
                if let driftPPM = result.driftPPM { item["driftPPM"] = rounded(driftPPM) }
                if let matchedAnchors = result.matchedAnchors { item["matchedAnchors"] = matchedAnchors }
                if let evaluatedAnchors = result.evaluatedAnchors { item["evaluatedAnchors"] = evaluatedAnchors }
                return item
            },
        ]
        if !report.failures.isEmpty {
            payload["failed"] = report.failures.map { failure -> [String: Any] in
                var item: [String: Any] = [
                    "clipId": failure.clipId,
                    "reason": failure.reason,
                ]
                if let method = failure.method { item["method"] = method.rawValue }
                if let confidence = failure.confidence { item["confidence"] = rounded(confidence) }
                return item
            }
        }
        guard let json = Self.jsonString(payload) else {
            throw ToolError("sync_audio: couldn't encode the synchronization report.")
        }
        return .ok(json)
    }
}
