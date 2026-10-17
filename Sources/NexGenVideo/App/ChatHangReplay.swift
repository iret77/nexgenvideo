import AppKit
import SwiftUI

@MainActor
enum ChatHangReplay {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["NGV_CHAT_HANG_REPLAY"] == "1"
    }

    static func runIfRequested() {
        guard isRequested else { return }
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
        let service = editor.agentService
        let image = imagePayload()
        for index in 0..<24 {
            appendGeneration(index, image: image, service: service)
        }
        let host = NSHostingView(rootView: EditorWindowContentView().environment(editor))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1470, height: 950),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        emit("started", step: 0)
        Task { @MainActor in
            guard await openActivity(in: window) != nil else {
                emit("activity-open-failed", step: 0)
                exit(2)
            }
            guard service.stageTask(.init(title: "Review generated sheets", systemImage: "photo",
                prompt: "Review the generated sheets.", requiresDirection: true)) else { exit(2) }
            service.isStreaming = true
            var focusedTicks = 0
            var diagnosticsWindow: NSWindow?
            for step in 1...1200 {
                NotificationCenter.default.post(
                    name: .claudeCodeStatusChanged,
                    object: ClaudeCodeLocator.Status(
                        executableURL: nil,
                        version: "offline-replay",
                        isAuthenticated: true
                    )
                )
                if step == 1 {
                    service.restoreComposerFocus()
                }
                if step % 80 == 20 {
                    service.isStreaming = false
                    do {
                        try service.presentDialog(reviewDialog(step))
                    } catch {
                        emit("dialog-failed", step: step)
                        exit(2)
                    }
                } else if step % 80 == 35 {
                    service.abandonDialog()
                    service.isStreaming = false
                    service.restoreComposerFocus()
                }
                if step.isMultiple(of: 40) {
                    service.isStreaming = false
                    appendGeneration(24 + step / 40, image: image, service: service)
                    service.isStreaming = true
                }
                if let last = service.messages.indices.last {
                    service.messages[last].blocks = [.text(String(
                        repeating: "Two deviations from the approved front. Waiting on your verdict. ",
                        count: step % 40 + 1
                    ))]
                }
                if step.isMultiple(of: 60) {
                    let widths: [CGFloat] = [1100, 1470, 1280, 1600]
                    window.setContentSize(NSSize(
                        width: widths[(step / 60) % widths.count],
                        height: 950
                    ))
                }
                host.layoutSubtreeIfNeeded()
                if step % 400 == 100 {
                    guard let activity = await openActivity(in: window) else {
                        emit("diagnostics-open-failed", step: step, reason: "activity control unavailable")
                        exit(2)
                    }
                    let clickFailure = WorkspaceUIAcceptance.click(identifier: "agent.diagnostics", in: activity)
                    guard clickFailure == nil,
                          let presented = await waitForControlWindow("agent.diagnostics.done") else {
                        emit("diagnostics-open-failed", step: step,
                             reason: clickFailure ?? "diagnostic window did not settle")
                        exit(2)
                    }
                    diagnosticsWindow = presented
                    if let content = presented.contentView { snapshot(content, step: step) }
                    emit("diagnostics-opened", step: step)
                } else if step % 400 == 300 {
                    guard let presented = await waitForControlWindow("agent.diagnostics.done"),
                          presented === diagnosticsWindow else {
                        emit("diagnostics-close-failed", step: step, reason: "diagnostic window did not remain presented")
                        exit(2)
                    }
                    let clickFailure = WorkspaceUIAcceptance.click(identifier: "agent.diagnostics.done", in: presented)
                    guard clickFailure == nil,
                          await WorkspaceUIAcceptance.waitUntil(timeout: .seconds(5), {
                              !presented.isVisible && controlWindow("agent.diagnostics.done") == nil
                          }) else {
                        if let content = presented.contentView { snapshot(content, step: step) }
                        emit("diagnostics-close-failed", step: step,
                             reason: clickFailure ?? "diagnostic window remained presented after click")
                        exit(2)
                    }
                    diagnosticsWindow = nil
                    emit("diagnostics-closed", step: step)
                    guard await openActivity(in: window) != nil else {
                        emit("activity-open-failed", step: step)
                        exit(2)
                    }
                }
                let activity = controlWindow("agent.diagnostics")
                let visibleHost = diagnosticsWindow?.contentView ?? activity?.contentView ?? host
                if activity?.isKeyWindow == true,
                   let input = activity?.firstResponder as? NSTextView,
                   !input.isHiddenOrHasHiddenAncestor, !input.visibleRect.isEmpty {
                    focusedTicks += 1
                }
                if step.isMultiple(of: 15),
                   let scroll = scrollViews(in: visibleHost).max(by: { $0.bounds.height < $1.bounds.height }),
                   let event = CGEvent(
                       scrollWheelEvent2Source: nil,
                       units: .pixel,
                       wheelCount: 1,
                       wheel1: step % 30 == 0 ? -240 : 240,
                       wheel2: 0,
                       wheel3: 0
                   ),
                   let wheel = NSEvent(cgEvent: event) {
                    scroll.scrollWheel(with: wheel)
                }
                if [10, 25, 600, 1200].contains(step) {
                    snapshot(visibleHost, step: step)
                }
                if step.isMultiple(of: 10) {
                    emit("progress", step: step)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard focusedTicks > 0 else {
                emit("composer-focus-missing", step: 1200)
                exit(2)
            }
            emit("composer-focus-verified", step: focusedTicks)
            emit("completed", step: 1200)
            window.orderOut(nil)
            exit(0)
        }
        app.run()
        exit(1)
    }

    private static func openActivity(in window: NSWindow) async -> NSWindow? {
        if controlWindow("agent.diagnostics") == nil {
            window.makeKeyAndOrderFront(nil)
            guard await waitForControlWindow("production.ai") === window,
                  WorkspaceUIAcceptance.click(identifier: "production.ai", in: window) == nil else { return nil }
        }
        return await waitForControlWindow("agent.diagnostics", requiresKeyWindow: false)
    }

    private static func controlWindow(_ identifier: String) -> NSWindow? {
        NSApp.windows.first { window in
            guard window.isVisible, let content = window.contentView else { return false }
            content.layoutSubtreeIfNeeded()
            guard let probe = WorkspaceUIAcceptance.findProbe(in: content, identifier: identifier) else { return false }
            return !probe.isHiddenOrHasHiddenAncestor && !probe.visibleRect.isEmpty
                && probe.bounds.width > 0 && probe.bounds.height > 0
        }
    }

    private static func waitForControlWindow(_ identifier: String, requiresKeyWindow: Bool = true) async -> NSWindow? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var previousWindow: NSWindow?
        var previousFrame: NSRect?
        var stableSince = clock.now
        while clock.now < deadline {
            if let window = controlWindow(identifier), !requiresKeyWindow || window.isKeyWindow {
                if window !== previousWindow || window.frame != previousFrame {
                    previousWindow = window
                    previousFrame = window.frame
                    stableSince = clock.now
                } else if clock.now - stableSince >= .milliseconds(300) {
                    return window
                }
            } else {
                previousWindow = nil
                previousFrame = nil
                stableSince = clock.now
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        return nil
    }

    private static func reviewDialog(_ step: Int) -> AgentDialog {
        AgentDialog(
            id: "replay-review-\(step)",
            title: "Review the two front sheets",
            symbol: "photo",
            intro: "Front sheets are the primary anchor. Side, back and three-quarter follow your approval.",
            costHint: nil,
            confirmLabel: "Apply",
            textField: .init(
                placeholder: "Extra correction for either sheet (optional)",
                multiline: true
            ),
            sections: [
                "AI cat — front sheet",
                "Claude Mouse — front sheet (pink inner ears missing)",
            ].enumerated().map { index, label in
                .init(
                    id: "sheet-\(index)",
                    label: label,
                    kind: .choices(
                        options: [
                            .init(id: "keep", label: "Keep"),
                            .init(id: "redo", label: "Regenerate"),
                        ],
                        multiSelect: false
                    ),
                    allowsCustom: true
                )
            }
        )
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
                .toolUse(id: toolID, name: "generate_image", inputJSON: "{}"),
            ]),
            AgentMessage(role: .user, blocks: [
                .toolResult(
                    toolUseId: toolID,
                    content: [.image(base64: image, mediaType: "image/png")],
                    isError: false
                ),
            ]),
            AgentMessage(role: .assistant, blocks: [.text("Waiting on your verdict.")]),
        ])
    }

    private static func imagePayload() -> String {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 512,
            pixelsHigh: 768,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.bitmapData!.initialize(
            repeating: 180,
            count: bitmap.bytesPerRow * bitmap.pixelsHigh
        )
        return bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    private static func emit(_ event: String, step: Int, reason: String? = nil) {
        var row: [String: Any] = [
            "event": event,
            "step": step,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if let reason { row["reason"] = reason }
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
