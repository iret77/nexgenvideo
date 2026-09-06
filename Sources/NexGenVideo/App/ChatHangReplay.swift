import AppKit
import SwiftUI

@MainActor
enum ChatHangReplay {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["NGV_CHAT_HANG_REPLAY"] == "1" else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        BundledFonts.register()
        AgentBackendPreference.set(.claudeCode)
        let editor = EditorViewModel()
        let service = editor.agentService
        service.currentSessionId = UUID()
        let image = imagePayload()
        for index in 0..<24 { appendGeneration(index, image: image, service: service) }
        service.isStreaming = true
        let host = NSHostingView(rootView: AgentPanelView().environment(editor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 950),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        emit("started", step: 0)
        Task { @MainActor in
            for step in 1...1200 {
                NotificationCenter.default.post(name: .claudeCodeStatusChanged, object:
                    ClaudeCodeLocator.Status(executableURL: nil, version: "offline-replay", isAuthenticated: true))
                if step == 1 { service.restoreComposerFocus() }
                if step.isMultiple(of: 40) {
                    service.isStreaming = false
                    appendGeneration(24 + step / 40, image: image, service: service)
                    service.isStreaming = true
                }
                if let last = service.messages.indices.last {
                    service.messages[last].blocks = [.text(String(repeating:
                        "Two deviations from the approved front. Waiting on your verdict. ", count: step % 40 + 1))]
                }
                if step.isMultiple(of: 60) {
                    let widths: [CGFloat] = [320, 540, 420, 640]
                    window.setContentSize(NSSize(width: widths[(step / 60) % widths.count], height: 950))
                }
                host.layoutSubtreeIfNeeded()
                if step.isMultiple(of: 10) { emit("progress", step: step) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            emit("completed", step: 1200)
            window.orderOut(nil)
            exit(0)
        }
        app.run()
        exit(1)
    }

    private static func appendGeneration(_ index: Int, image: String, service: AgentService) {
        let toolID = "replay-image-\(index)"
        service.messages.append(contentsOf: [
            AgentMessage(role: .user, blocks: [.text("Keep this sheet and continue.")]),
            AgentMessage(role: .assistant, blocks: [
                .toolUse(id: toolID, name: "generate_image", inputJSON: "{}")
            ]),
            AgentMessage(role: .user, blocks: [
                .toolResult(toolUseId: toolID, content: [.image(base64: image, mediaType: "image/png")], isError: false)
            ]),
            AgentMessage(role: .assistant, blocks: [.text("Waiting on your verdict.")]),
        ])
    }

    private static func imagePayload() -> String {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 768,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.bitmapData!.initialize(repeating: 180, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    private static func emit(_ event: String, step: Int) {
        let row: [String: Any] = ["event": event, "step": step,
                                  "os": ProcessInfo.processInfo.operatingSystemVersionString]
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
