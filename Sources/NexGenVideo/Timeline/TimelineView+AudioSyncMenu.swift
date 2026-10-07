import AppKit

extension TimelineView {
    @objc func performSynchronize(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let referenceClipId = info["referenceClipId"] as? String,
              let targetClipIds = info["targetClipIds"] as? [String], !targetClipIds.isEmpty else { return }
        let mode = (info["mode"] as? String).flatMap(EditorViewModel.SyncMode.init) ?? .auto
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await editor.syncClips(
                referenceClipId: referenceClipId,
                targetClipIds: targetClipIds,
                mode: mode
            )
            editor.mediaPanelToast = MediaPanelToast(
                message: Self.synchronizeSummary(report),
                kind: report.synced.isEmpty ? .warning : .success
            )
            needsDisplay = true
        }
    }

    private static func synchronizeSummary(_ report: EditorViewModel.SyncBatchReport) -> String {
        if report.synced.isEmpty, let first = report.failures.first {
            return report.failures.count == 1 ? first.reason : "Couldn't align \(report.failures.count) clips."
        }
        if report.synced.count == 1, report.failures.isEmpty, let result = report.synced.first {
            let confidence = Int((result.confidence * 100).rounded())
            let method = result.method == .sourceTimecode ? "source timecode" : "audio"
            var message = "Synchronized by \(method) (\(confidence)% confidence"
            if let matched = result.matchedAnchors, let evaluated = result.evaluatedAnchors {
                message += ", \(matched)/\(evaluated) anchors"
            }
            return message + ")."
        }
        let timecodeCount = report.synced.count(where: { $0.method == .sourceTimecode })
        let audioCount = report.synced.count(where: { $0.method == .audio })
        var msg = "Synchronized \(report.synced.count) clip\(report.synced.count == 1 ? "" : "s")"
        switch (timecodeCount, audioCount) {
        case (0, _): msg += " by audio"
        case (_, 0): msg += " by source timecode"
        default: msg += " (\(timecodeCount) by timecode, \(audioCount) by audio)"
        }
        if report.shiftedFrames > 0 { msg += "; group moved right to fit" }
        if !report.failures.isEmpty { msg += "; \(report.failures.count) couldn't align" }
        return msg + "."
    }
}
