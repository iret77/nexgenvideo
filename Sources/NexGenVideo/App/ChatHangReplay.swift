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
                if step % 80 == 20 {
                    service.isStreaming = false
                    do { try service.presentDialog(reviewDialog(step)) }
                    catch { emit("dialog-failed", step: step); exit(2) }
                } else if step % 80 == 35 {
                    service.abandonDialog()
                    service.isStreaming = true
                    service.restoreComposerFocus()
                }
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
                if step.isMultiple(of: 15), let scroll = scrollViews(in: host).max(by: { $0.bounds.height < $1.bounds.height }),
                   let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                       wheel1: step % 30 == 0 ? -240 : 240, wheel2: 0, wheel3: 0),
                   let wheel = NSEvent(cgEvent: event) {
                    scroll.scrollWheel(with: wheel)
                }
                if [10, 25, 600, 1200].contains(step) { snapshot(host, step: step) }
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

    private static func reviewDialog(_ step: Int) -> AgentDialog {
        AgentDialog(id: "replay-review-\(step)", title: "Review the two front sheets", symbol: "photo",
                    intro: "Front sheets are the primary anchor. Side, back and three-quarter follow your approval.",
                    costHint: nil, confirmLabel: "Apply",
                    textField: .init(placeholder: "Extra correction for either sheet (optional)", multiline: true),
                    sections: ["AI cat — front sheet", "Claude Mouse — front sheet (pink inner ears missing)"].enumerated().map { index, label in
                        .init(id: "sheet-\(index)", label: label,
                              kind: .choices(options: [.init(id: "keep", label: "Keep"),
                                                       .init(id: "redo", label: "Regenerate")], multiSelect: false),
                              allowsCustom: true)
                    })
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func snapshot(_ view: NSView, step: Int) {
        guard let directory = ProcessInfo.processInfo.environment["NGV_CHAT_REPLAY_EVIDENCE"],
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("panel-\(step).png"))
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
