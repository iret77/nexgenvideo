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
            let recordedScroll = recordedTranscriptViewport(in: records)
            guard !matchGeometry || recordedScroll != nil else { exit(70) }
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
                            if let recordedScroll { try host.matchViewport(recordedScroll) }
                            try await scrollTranscriptToBottom(in: host)
                            try await Task.sleep(for: .milliseconds(100))
                            writeProgress(sequence: decoded.sequence, window: window, host: host, environment: environment)
                        }
                    }
                    try await Task.sleep(for: .seconds(matchGeometry ? 30 : 2))
                    writeProgress(sequence: nil, window: window, host: host, environment: environment)
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

    private static func scrollTranscriptToBottom(in host: ReplayHost) async throws {
        let scroll = try host.transcriptScroll()
        guard let document = scroll.documentView else { throw CocoaError(.coderValueNotFound) }
        let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
        let target = String(describing: ObjectIdentifier(scroll))
        if scrollMotion["target"] as? String != target, bottom > 120 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom / 2))
            scroll.reflectScrolledClipView(scroll.contentView)
            let before = scroll.contentView.bounds.origin.y
            sendScrollGesture(to: scroll, delta: 20)
            try await Task.sleep(for: .milliseconds(20))
            let after = scroll.contentView.bounds.origin.y
            if after <= before - 1 {
                scrollMotion = ["target": target, "before": before, "after": after,
                    "contentHeight": document.frame.height, "viewportHeight": scroll.contentView.bounds.height]
            }
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        sendScrollGesture(to: scroll, delta: -20)
    }

    private static func sendScrollGesture(to scroll: NSScrollView, delta: Int32) {
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: delta, wheel2: 0, wheel3: 0) else { continue }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            if let wheel = NSEvent(cgEvent: event) {
                scroll.scrollWheel(with: wheel)
                scrollEventsSent += 1
                lastScrollTarget = String(describing: ObjectIdentifier(scroll))
            }
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
        guard let record = records.last(where: { $0.operation == .scroll && $0.values.count >= 5 }),
              record.values[4].isFinite, record.values[4] > 0,
              record.values[2].isFinite, record.values[2] > 0 else { return nil }
        return CGSize(width: record.values[4], height: record.values[2])
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

    private static func writeProgress(sequence: UInt64?, window: NSWindow, host: ReplayHost, environment: [String: String]) {
        guard let path = environment["NGV_DIAGNOSTIC_REPLAY_PROGRESS"],
              let content = window.contentView else { return }
        let views = descendants(of: content)
        let scrolls = views.compactMap { $0 as? NSScrollView }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        let geometry = scrolls.map { scroll -> [String: Double] in
            ["width": Double(scroll.contentView.bounds.width), "height": Double(scroll.contentView.bounds.height),
             "offset": Double(scroll.contentView.bounds.origin.y),
             "contentHeight": Double(scroll.documentView?.frame.height ?? 0)]
        }
        let transcriptScroll = try? host.transcriptScroll()
        let progress: [String: Any] = ["sequence": sequence.map { $0 as Any } ?? NSNull(),
                                       "finished": sequence == nil, "scrolls": geometry,
                                       "windowNumber": window.windowNumber,
                                       "windowWidth": window.frame.width,
                                       "windowHeight": window.frame.height,
                                       "maximumPulseGap": maximumPulseGap,
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
