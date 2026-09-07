import AppKit
import CryptoKit
import HangDiagnostics
import SwiftUI

@MainActor
enum HangDiagnosticReplay {
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
            let editor = EditorViewModel()
            editor.workspaceFocus = .produce
            editor.agentPanelVisible = true
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1470, height: 950),
                styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: EditorWindowContentView().environment(editor).allowsHitTesting(false))
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            Task { @MainActor in
                var previous: Data?
                var priorTime: Double?
                do {
                    for file in files {
                        let decoded = try await Task.detached { () -> DiagnosticReplayDelta in
                            let encrypted = try Data(contentsOf: file)
                            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key,
                                authenticating: Data(folder.lastPathComponent.utf8))
                            return try JSONDecoder().decode(DiagnosticReplayDelta.self, from: bytes)
                        }.value
                        if let priorTime {
                            try await Task.sleep(for: .seconds(max(0, decoded.uptime - priorTime)))
                        }
                        let bytes = try decoded.apply(to: decoded.predecessor == nil ? nil : previous)
                        let state = try JSONDecoder().decode(HangDiagnosticTranscript.self, from: bytes)
                        previous = bytes
                        priorTime = decoded.uptime
                        let service = editor.agentService
                        if let project = state.project { editor.restoreDiagnosticProject(project) }
                        try service.restoreDiagnosticTranscript(state)
                    }
                    try await Task.sleep(for: .seconds(2))
                    exit(0)
                } catch { exit(67) }
            }
            app.run()
        } catch { exit(68) }
        exit(69)
    }
}
