import AppKit
import CryptoKit
import HangDiagnostics
import SwiftUI

@MainActor
enum HangDiagnosticReplay {
    private static var lastPulse = ProcessInfo.processInfo.systemUptime
    private static var maximumPulseGap = 0.0

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
            AgentBackendPreference.set(.claudeCode)
            let editor = EditorViewModel()
            editor.workspaceFocus = .produce
            editor.agentPanelVisible = true
            let matchGeometry = environment["NGV_DIAGNOSTIC_REPLAY_MATCH_GEOMETRY"] == "1"
            let records = try (matchGeometry ? structuralRecords(in: folder) : [])
            let recordedWindow = records.last { $0.operation == .window && $0.values.count >= 6 && $0.values[5] == 1 }
            let recordedScroll = records.last { $0.operation == .scroll && $0.values.count >= 5 }
            if matchGeometry { editor.cockpitTab = .review }
            let host = NSHostingController(rootView: EditorWindowContentView().environment(editor).allowsHitTesting(false))
            host.safeAreaRegions = []
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
                            if let scroll = recordedScroll {
                                restoreSidebarWidth(scroll.values[4], in: window)
                            }
                            scrollTranscriptToBottom(in: window)
                            try await Task.sleep(for: .milliseconds(100))
                            writeProgress(sequence: decoded.sequence, window: window, environment: environment)
                        }
                    }
                    try await Task.sleep(for: .seconds(matchGeometry ? 30 : 2))
                    writeProgress(sequence: nil, window: window, environment: environment)
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

    private static func scrollTranscriptToBottom(in window: NSWindow) {
        guard let content = window.contentView,
              let split = descendants(of: content).compactMap({ $0 as? NSSplitView })
                .first(where: { $0.autosaveName == "editor.produce.root" }),
              let sidebar = split.subviews.first,
              let scroll = descendants(of: sidebar).compactMap({ $0 as? NSScrollView })
                .filter({ !$0.isHiddenOrHasHiddenAncestor })
                .max(by: { $0.contentView.bounds.height < $1.contentView.bounds.height }),
              let document = scroll.documentView else { return }
        let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: -20, wheel2: 0, wheel3: 0) else { continue }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            if let wheel = NSEvent(cgEvent: event) { scroll.scrollWheel(with: wheel) }
        }
    }

    private static func structuralRecords(in folder: URL) throws -> [DiagnosticRecord] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "json" }
            .flatMap { try JSONDecoder().decode([DiagnosticRecord].self, from: Data(contentsOf: $0)) }
            .sorted { $0.sequence < $1.sequence }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func restoreSidebarWidth(_ width: Double, in window: NSWindow) {
        guard let content = window.contentView,
              let split = descendants(of: content).compactMap({ $0 as? NSSplitView })
                .first(where: { $0.autosaveName == "editor.produce.root" }),
              let sidebar = split.subviews.first else { return }
        let target = width + AppTheme.Layout.panelGap
        if abs(sidebar.frame.width - target) > 0.5 {
            split.setPosition(target, ofDividerAt: 0)
        }
    }

    private static func writeProgress(sequence: UInt64?, window: NSWindow, environment: [String: String]) {
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
        let progress: [String: Any] = ["sequence": sequence.map { $0 as Any } ?? NSNull(),
                                       "finished": sequence == nil, "scrolls": geometry,
                                       "windowNumber": window.windowNumber,
                                       "windowWidth": window.frame.width,
                                       "windowHeight": window.frame.height,
                                       "maximumPulseGap": maximumPulseGap,
                                       "editableTextViews": views.compactMap { $0 as? NSTextView }
                                           .filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }.count,
                                       "views": views.count,
                                       "constraints": views.reduce(0) { $0 + $1.constraints.count }]
        if let data = try? JSONSerialization.data(withJSONObject: progress) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
