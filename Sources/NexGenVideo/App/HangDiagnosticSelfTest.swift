import AppKit
import SwiftUI

enum HangDiagnosticSelfTest {
    @MainActor private static var editor: EditorViewModel?
    @MainActor private static var window: NSWindow?
    static var requested: Bool {
        ProcessInfo.processInfo.environment["NGV_HANG_SELFTEST"] == "wait"
            || ProcessInfo.processInfo.environment["NGV_HANG_SELFTEST"] == "spin"
    }

    @MainActor
    static func start() {
        let content = ProcessInfo.processInfo.environment["NGV_HANG_SELFTEST_KEY"] != nil
        HangDiagnosticRecorder.shared.start(includeContent: content)
        if content {
            let editor = EditorViewModel()
            editor.workspaceFocus = .produce
            editor.agentPanelVisible = true
            self.editor = editor
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1470, height: 950),
                styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: EditorWindowContentView().environment(editor))
            window.makeKeyAndOrderFront(nil)
            self.window = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                editor.agentService.messages = [AgentMessage(role: .assistant, blocks: [.text("Synthetic recording control.")])]
                editor.agentService.isStreaming = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                editor.agentService.messages.append(AgentMessage(role: .assistant,
                    blocks: [.text("NGV_DIAGNOSTIC_REPLAY_CONTROL")]))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let spin = ProcessInfo.processInfo.environment["NGV_HANG_SELFTEST"] == "spin"
            let id = HangDiagnosticRecorder.shared.record(spin ? .testSpin : .testWait)
            if spin { knownMainThreadSpin() } else { knownMainThreadWait() }
            HangDiagnosticRecorder.shared.record(spin ? .testSpin : .testWait, correlation: id, end: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task { @MainActor in
                    if let output = ProcessInfo.processInfo.environment["NGV_HANG_SELFTEST_EXPORT"] {
                        do {
                            try await HangDiagnosticRecorder.shared.exportCurrentForSelfTest(to: URL(fileURLWithPath: output))
                        } catch { exit(70) }
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    static func injectReplayControl(_ messages: [AgentMessage]) {
        guard ProcessInfo.processInfo.environment["NGV_DIAGNOSTIC_REPLAY"] != nil,
              ProcessInfo.processInfo.environment["NGV_DIAGNOSTIC_REPLAY_FAULT"] == "1",
              messages.contains(where: { message in
                  message.blocks.contains { if case .text("NGV_DIAGNOSTIC_REPLAY_CONTROL") = $0 { true } else { false } }
              }) else { return }
        Thread.sleep(forTimeInterval: 30)
    }

    @inline(never) private static func knownMainThreadWait() {
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 20)
    }

    @inline(never) private static func knownMainThreadSpin() {
        let end = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < end { _ = mach_absolute_time() }
    }
}
