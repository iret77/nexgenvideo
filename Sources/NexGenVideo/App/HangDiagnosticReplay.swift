import AppKit
import CryptoKit
import HangDiagnostics
import SwiftUI

@MainActor
enum HangDiagnosticReplay {
    private static var lastPulse = ProcessInfo.processInfo.systemUptime
    private static var maximumPulseGap = 0.0
    private static var scrollEventsSent = 0
    private static var lastScrollTarget: String?
    private static var scrollMotion: [String: Any] = [:]

    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["NGV_DIAGNOSTIC_REPLAY"],
              let keyPath = environment["NGV_DIAGNOSTIC_KEY_FILE"] else { return }
        let folder = URL(fileURLWithPath: path)
        guard UUID(uuidString: folder.lastPathComponent) != nil else { exit(64) }
        do {
            let keyText = try String(contentsOfFile: keyPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let bytes = Data(base64Encoded: keyText), bytes.count == 32 else { exit(65) }
            let key = SymmetricKey(data: bytes)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("replay-") && $0.pathExtension == "enc" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else { exit(66) }
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            BundledFonts.register()
            let editor = EditorViewModel(
                agentService: AgentService(
                    backend: .claudeCode,
                    refreshBackendStatusOnInit: false
                )
            )
            editor.setWorkspaceFocus(.production)
            let matchGeometry = environment["NGV_DIAGNOSTIC_REPLAY_MATCH_GEOMETRY"] == "1"
            let records = try (matchGeometry ? structuralRecords(in: folder) : [])
            let recordedWindow = recordedEditorWindow(in: records)
            let geometry = transcriptGeometry(in: records,
                comparisonViewport: environment["NGV_DIAGNOSTIC_REPLAY_COMPARISON_VIEWPORT"])
            guard !matchGeometry || (recordedWindow != nil && geometry != nil) else { exit(70) }
            let activationTimeline = recordedActivationTimeline(in: records)
            let host = ReplayHost(editor: editor)
            let window = ReplayWindow(contentViewController: host)
            window.styleMask.insert([.fullSizeContentView, .resizable, .closable])
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.setFrame(NSRect(x: 0, y: 0, width: 1470, height: 950), display: false)
            if let recordedWindow {
                window.setFrame(NSRect(x: 0, y: 0, width: recordedWindow.values[1],
                                       height: recordedWindow.values[2]), display: false)
            }
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            let pulse = Timer(timeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let now = ProcessInfo.processInfo.systemUptime
                    maximumPulseGap = max(maximumPulseGap, now - lastPulse)
                    lastPulse = now
                }
            }
            RunLoop.main.add(pulse, forMode: .common)
            Task { @MainActor in
                var previous: HangDiagnosticTranscript?
                var previousDigest: String?
                var priorTime: Double?
                var activationIndex = 0
                var isReplayActive = true
                do {
                    for file in files {
                        let (decoded, digest) = try await Task.detached { () -> (HangDiagnosticReplayFrame, String) in
                            let encrypted = try Data(contentsOf: file)
                            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key,
                                authenticating: Data(folder.lastPathComponent.utf8))
                            return (try JSONDecoder().decode(HangDiagnosticReplayFrame.self, from: bytes), DiagnosticFiles.digest(bytes))
                        }.value
                        if let priorTime {
                            try await Task.sleep(for: .seconds(max(0, decoded.uptime - priorTime)))
                        }
                        while activationIndex < activationTimeline.count,
                              activationTimeline[activationIndex].uptime <= decoded.uptime {
                            let active = activationTimeline[activationIndex].active
                            if active != isReplayActive {
                                if active {
                                    window.makeKeyAndOrderFront(nil)
                                    app.activate(ignoringOtherApps: true)
                                } else {
                                    app.deactivate()
                                }
                                isReplayActive = active
                            }
                            activationIndex += 1
                        }
                        guard decoded.predecessor == nil || decoded.predecessor == previousDigest else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        let state = try decoded.apply(to: decoded.predecessor == nil ? nil : previous)
                        previous = state
                        previousDigest = digest
                        priorTime = decoded.uptime
                        let service = editor.agentService
                        if decoded.projectChanged, let project = state.project { editor.restoreDiagnosticProject(project) }
                        try service.restoreDiagnosticTranscript(state)
                        if matchGeometry {
                            try await Task.sleep(for: .milliseconds(20))
                            if let geometry { try host.matchViewport(geometry.viewport) }
                            try await scrollTranscriptToBottom(in: host)
                            try await Task.sleep(for: .milliseconds(100))
                            writeProgress(sequence: decoded.sequence, window: window, host: host, geometry: geometry, environment: environment)
                        }
                    }
                    try await Task.sleep(for: .seconds(matchGeometry ? 30 : 2))
                    writeProgress(sequence: nil, window: window, host: host, geometry: geometry, environment: environment)
                    exit(0)
                } catch { exit(67) }
            }
            app.run()
        } catch { exit(68) }
        exit(69)
    }

    private final class ReplayWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private struct ScrollSnapshot {
        let scroll: NSScrollView
        let document: NSView
        let documentFrame: NSRect
        let viewport: NSRect

        var target: String { String(describing: ObjectIdentifier(scroll)) }
        var bottom: CGFloat { max(0, documentFrame.height - viewport.height) }
        var isInterior: Bool { viewport.minY > 0 && viewport.minY < bottom }

        func hasSameGeometry(as other: Self) -> Bool {
            scroll === other.scroll && document === other.document
                && documentFrame == other.documentFrame && viewport.size == other.viewport.size
        }
    }

    private static func scrollSnapshot(in host: ReplayHost) throws -> ScrollSnapshot {
        host.view.layoutSubtreeIfNeeded()
        let scroll = try host.transcriptScroll()
        guard let document = scroll.documentView else { throw CocoaError(.coderValueNotFound) }
        let frame = document.frame
        let viewport = scroll.contentView.bounds
        guard [frame.minX, frame.minY, frame.width, frame.height,
               viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy(\.isFinite),
              frame.height >= 0, viewport.width > 0, viewport.height > 0 else {
            throw CocoaError(.coderInvalidValue)
        }
        return ScrollSnapshot(scroll: scroll, document: document, documentFrame: frame, viewport: viewport)
    }

    private static func stableScrollSnapshot(in host: ReplayHost, matching geometry: ScrollSnapshot? = nil) async throws -> ScrollSnapshot? {
        var previous = try scrollSnapshot(in: host)
        if let geometry, !previous.hasSameGeometry(as: geometry) { return nil }
        var stableSamples = 0
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(20))
            let current = try scrollSnapshot(in: host)
            if let geometry, !current.hasSameGeometry(as: geometry) { return nil }
            stableSamples = current.hasSameGeometry(as: previous) && current.viewport == previous.viewport
                ? stableSamples + 1 : 0
            if stableSamples == 2 { return current }
            previous = current
        }
        return nil
    }

    private static func scrollTranscriptToBottom(in host: ReplayHost) async throws {
        let initial = try scrollSnapshot(in: host)
        if scrollMotion["target"] as? String != initial.target,
           let ready = try await stableScrollSnapshot(in: host), ready.bottom > 120 {
            ready.scroll.contentView.scroll(to: NSPoint(x: 0, y: ready.bottom / 2))
            ready.scroll.reflectScrolledClipView(ready.scroll.contentView)
            if let before = try await stableScrollSnapshot(in: host),
               before.scroll === ready.scroll, before.document === ready.document, before.isInterior {
                try sendScrollGesture(to: before.scroll, delta: 20)
                if let after = try await stableScrollSnapshot(in: host, matching: before), after.isInterior,
                   after.viewport.minY <= before.viewport.minY - 1 {
                    scrollMotion = ["target": before.target, "before": before.viewport.minY,
                        "after": after.viewport.minY, "contentHeight": before.documentFrame.height,
                        "viewportHeight": before.viewport.height]
                }
            }
        }
        let current = try scrollSnapshot(in: host)
        current.scroll.contentView.scroll(to: NSPoint(x: 0, y: current.bottom))
        current.scroll.reflectScrolledClipView(current.scroll.contentView)
        try sendScrollGesture(to: current.scroll, delta: -20)
    }

    static func scrollGestureEvents(delta: Int32, location: CGPoint) throws -> [NSEvent] {
        let beganDelta = delta.signum()
        return try [(CGScrollPhase.began, beganDelta), (.changed, delta - beganDelta), (.ended, 0)].map { phase, amount in
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: amount, wheel2: 0, wheel3: 0) else { throw CocoaError(.coderInvalidValue) }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            event.location = location
            guard let wheel = NSEvent(cgEvent: event) else { throw CocoaError(.coderInvalidValue) }
            return wheel
        }
    }

    private static func sendScrollGesture(to scroll: NSScrollView, delta: Int32) throws {
        guard let window = scroll.window, let screen = NSScreen.screens.first else { throw CocoaError(.coderValueNotFound) }
        let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let point = window.convertPoint(toScreen: center)
        let location = CGPoint(x: point.x, y: screen.frame.height - point.y)
        for wheel in try scrollGestureEvents(delta: delta, location: location) {
            scroll.scrollWheel(with: wheel)
            scrollEventsSent += 1
            lastScrollTarget = String(describing: ObjectIdentifier(scroll))
        }
    }

    private static func structuralRecords(in folder: URL) throws -> [DiagnosticRecord] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "json" }
            .flatMap { try JSONDecoder().decode([DiagnosticRecord].self, from: Data(contentsOf: $0)) }
            .sorted { $0.sequence < $1.sequence }
    }

    static func recordedEditorWindow(in records: [DiagnosticRecord]) -> DiagnosticRecord? {
        let windows = records.filter { $0.operation == .window && $0.values.count >= 3 }
        guard windows.allSatisfy({ !$0.hadNonFiniteValues
            && $0.values[1].isFinite && $0.values[1] > 0
            && $0.values[2].isFinite && $0.values[2] > 0 }) else { return nil }
        guard let editorWindowNumber = windows.max(by: {
            let leftArea = $0.values[1] * $0.values[2]
            let rightArea = $1.values[1] * $1.values[2]
            return leftArea == rightArea ? $0.sequence < $1.sequence : leftArea < rightArea
        })?.values[0] else { return nil }
        return windows
            .filter { $0.values[0] == editorWindowNumber }
            .max { $0.sequence < $1.sequence }
    }

    static func recordedTranscriptViewport(in records: [DiagnosticRecord]) -> CGSize? {
        guard let record = records.filter({ $0.operation == .scroll && $0.values.count >= 5 })
                .max(by: { $0.sequence < $1.sequence }), !record.hadNonFiniteValues,
              record.values[4].isFinite, record.values[4] > 0,
              record.values[2].isFinite, record.values[2] > 0 else { return nil }
        return CGSize(width: record.values[4], height: record.values[2])
    }

    struct TranscriptGeometry {
        let source: String
        let viewport: CGSize
    }

    static func transcriptGeometry(in records: [DiagnosticRecord], comparisonViewport: String?) -> TranscriptGeometry? {
        if records.contains(where: { $0.operation == .scroll && $0.values.count >= 5 }) {
            guard let viewport = recordedTranscriptViewport(in: records) else { return nil }
            return TranscriptGeometry(source: "recorded", viewport: viewport)
        }
        guard let parts = comparisonViewport?.split(separator: "x", omittingEmptySubsequences: false),
              parts.count == 2, let width = Double(String(parts[0])), let height = Double(String(parts[1])),
              width.isFinite, width > 0, height.isFinite, height > 0 else { return nil }
        return TranscriptGeometry(source: "comparison", viewport: CGSize(width: width, height: height))
    }

    struct ActivationSample: Equatable {
        var uptime: Double
        var active: Bool
    }

    static func recordedActivationTimeline(in records: [DiagnosticRecord]) -> [ActivationSample] {
        let windows = records
            .filter { $0.operation == .window && $0.values.count >= 6 }
            .sorted { $0.uptime < $1.uptime }
        var samples: [ActivationSample] = []
        for record in windows {
            let active = record.values[5] == 1
            if let index = samples.indices.last,
               record.uptime - samples[index].uptime <= 0.05 {
                samples[index].active = samples[index].active || active
            } else {
                samples.append(ActivationSample(uptime: record.uptime, active: active))
            }
        }
        return samples.enumerated().compactMap { index, sample in
            index == 0 || samples[index - 1].active != sample.active ? sample : nil
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private final class ReplayHost: NSViewController {
        private let transcript: NSHostingView<AnyView>

        init(editor: EditorViewModel) {
            transcript = NSHostingView(rootView: AnyView(AgentPanelView(replayTranscriptOnly: true)
                .interfaceStyle(palette: editor.projectPalette).environment(editor).allowsHitTesting(false)))
            transcript.sizingOptions = []
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func loadView() {
            view = NSView(frame: NSRect(origin: .zero, size: AppTheme.Acceptance.workbenchViewport))
            transcript.frame = view.bounds
            transcript.autoresizingMask = [.width, .height]
            view.addSubview(transcript)
        }

        func transcriptScroll() throws -> NSScrollView {
            let probes = descendants(of: transcript).compactMap { $0 as? HangReplayTranscriptProbe.ProbeView }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
            guard probes.count == 1, let probe = probes.first,
                  let scroll = probe.enclosingScrollView,
                  scroll.isDescendant(of: transcript), let document = scroll.documentView,
                  probe.isDescendant(of: document) else {
                throw CocoaError(.coderValueNotFound)
            }
            return scroll
        }

        func matchViewport(_ target: CGSize) throws {
            transcript.autoresizingMask = []
            transcript.setFrameSize(target)
            for _ in 0..<3 {
                transcript.layoutSubtreeIfNeeded()
                let actual = try transcriptScroll().contentView.bounds.size
                if abs(actual.width - target.width) <= 1 && abs(actual.height - target.height) <= 1 { return }
                transcript.setFrameSize(CGSize(width: transcript.frame.width + target.width - actual.width,
                    height: transcript.frame.height + target.height - actual.height))
            }
            throw CocoaError(.coderInvalidValue)
        }
    }

    private static func writeProgress(sequence: UInt64?, window: NSWindow, host: ReplayHost,
                                      geometry: TranscriptGeometry?, environment: [String: String]) {
        guard let path = environment["NGV_DIAGNOSTIC_REPLAY_PROGRESS"],
              let content = window.contentView else { return }
        let views = descendants(of: content)
        let scrolls = views.compactMap { $0 as? NSScrollView }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        let scrollGeometry = scrolls.map { scroll -> [String: Double] in
            ["width": Double(scroll.contentView.bounds.width), "height": Double(scroll.contentView.bounds.height),
             "offset": Double(scroll.contentView.bounds.origin.y),
             "contentHeight": Double(scroll.documentView?.frame.height ?? 0)]
        }
        let transcriptScroll = try? host.transcriptScroll()
        let progress: [String: Any] = ["sequence": sequence.map { $0 as Any } ?? NSNull(),
                                       "finished": sequence == nil, "scrolls": scrollGeometry,
                                       "windowNumber": window.windowNumber,
                                       "windowWidth": window.frame.width,
                                       "windowHeight": window.frame.height,
                                       "maximumPulseGap": maximumPulseGap,
                                       "transcriptGeometrySource": geometry?.source ?? "unavailable",
                                       "transcriptWidth": transcriptScroll?.contentView.bounds.width ?? 0,
                                       "transcriptHeight": transcriptScroll?.contentView.bounds.height ?? 0,
                                       "scrollEventsSent": scrollEventsSent,
                                       "scrollTarget": lastScrollTarget ?? "",
                                       "transcriptScrollTarget": transcriptScroll.map { String(describing: ObjectIdentifier($0)) } ?? "",
                                       "scrollMotion": scrollMotion,
                                       "editableTextViews": views.compactMap { $0 as? NSTextView }
                                           .filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }.count,
                                       "views": views.count,
                                       "constraints": views.reduce(0) { $0 + $1.constraints.count }]
        if let data = try? JSONSerialization.data(withJSONObject: progress) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

struct HangReplayTranscriptProbe: NSViewRepresentable {
    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) {}
}
