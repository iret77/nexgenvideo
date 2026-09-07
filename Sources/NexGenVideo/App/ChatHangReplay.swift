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
        editor.workspaceFocus = .produce
        editor.agentPanelVisible = true
        let projectPath = ProcessInfo.processInfo.environment["NGV_CHAT_REPLAY_PROJECT"]
        if let projectPath {
            do { try prepareProject(URL(fileURLWithPath: projectPath), editor: editor) }
            catch { emit("project-load-failed", step: 0); exit(2) }
        }
        let service = editor.agentService
        let fixturePath = ProcessInfo.processInfo.environment["NGV_CHAT_REPLAY_FIXTURE"]
        let image: String
        let recordedMessages: [AgentMessage]
        if let fixturePath {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let session = try decoder.decode(ChatSession.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
                guard !session.messages.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                service.sessions = [session]
                service.currentSessionId = session.id
                recordedMessages = session.messages
                service.messages = []
                image = ""
            } catch {
                emit("fixture-load-failed", step: 0)
                exit(2)
            }
        } else {
            recordedMessages = []
            service.currentSessionId = UUID()
            image = imagePayload()
            for index in 0..<24 { appendGeneration(index, image: image, service: service) }
        }
        service.isStreaming = true
        let host = NSHostingView(rootView: EditorWindowContentView().environment(editor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1470, height: 950),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        emit("started", step: 0)
        Task { @MainActor in
            if projectPath != nil {
                await editor.refreshEngineState()
                guard editor.packWiringBroken == nil,
                      let state = editor.projectState,
                      state.phases.count == 11,
                      state.phases.filter(\.approved).count == 6,
                      state.nextPhaseName == "bible" else {
                    emit("project-state-mismatch", step: 0)
                    exit(2)
                }
                emit("project-state-verified", step: 0)
            }
            let ticksPerMessage = max(2, 1000 / max(1, recordedMessages.count))
            var focusedTicks = 0
            for step in 1...1200 {
                NotificationCenter.default.post(name: .claudeCodeStatusChanged, object:
                    ClaudeCodeLocator.Status(executableURL: nil, version: "offline-replay", isAuthenticated: true))
                if step == 1 { service.prefillInput("") }
                if fixturePath != nil {
                    do {
                        try replayRecordedMessages(recordedMessages, step: step,
                                                   ticksPerMessage: ticksPerMessage, service: service)
                    } catch { emit("recorded-dialog-failed", step: step); exit(2) }
                } else if step % 80 == 20 {
                    service.isStreaming = false
                    do { try service.presentDialog(reviewDialog(step)) }
                    catch { emit("dialog-failed", step: step); exit(2) }
                } else if fixturePath == nil && step % 80 == 35 {
                    service.abandonDialog()
                    service.isStreaming = true
                    service.prefillInput("")
                }
                if fixturePath == nil && step.isMultiple(of: 40) {
                    service.isStreaming = false
                    appendGeneration(24 + step / 40, image: image, service: service)
                    service.isStreaming = true
                }
                if fixturePath == nil, let last = service.messages.indices.last {
                    service.messages[last].blocks = [.text(String(repeating:
                        "Two deviations from the approved front. Waiting on your verdict. ", count: step % 40 + 1))]
                }
                if step.isMultiple(of: 60) {
                    let widths: [CGFloat] = [1100, 1470, 1280, 1600]
                    window.setContentSize(NSSize(width: widths[(step / 60) % widths.count], height: 950))
                }
                host.layoutSubtreeIfNeeded()
                if window.firstResponder is NSTextView { focusedTicks += 1 }
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
            guard focusedTicks > 0 else { emit("composer-focus-missing", step: 1200); exit(2) }
            emit("composer-focus-verified", step: focusedTicks)
            emit("completed", step: 1200)
            window.orderOut(nil)
            exit(0)
        }
        app.run()
        exit(1)
    }

    private static func prepareProject(_ root: URL, editor: EditorViewModel) throws {
        guard case .bound(let binding) = ProjectPluginSettings.bindingResolution(projectURL: root),
              let packPath = ProcessInfo.processInfo.environment["NGV_CHAT_REPLAY_PACK"],
              let identity = ProjectIdentity.existingUUID(for: root) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let source = URL(fileURLWithPath: packPath)
        guard let info = PluginBundleInfo(bundleURL: source),
              info.id == binding.id, info.version == binding.version,
              info.projectSchema == binding.projectSchema else { throw CocoaError(.fileReadCorruptFile) }
        let destination = PluginPaths.installURL(id: binding.id, version: binding.version)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        guard PluginLoader.load(at: destination).state == .loaded else { throw CocoaError(.fileReadCorruptFile) }
        editor.timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: root.appendingPathComponent(Project.timelineFilename)))
        editor.mediaManifest = try JSONDecoder().decode(MediaManifest.self, from: Data(contentsOf: root.appendingPathComponent(Project.manifestFilename)))
        editor.adoptWorkingCopy(.init(home: root, recoveredUnsaved: false, generation: UUID()),
                               key: "p-" + identity, packageURL: root)
    }

    private static func replayRecordedMessages(_ messages: [AgentMessage], step: Int,
                                               ticksPerMessage: Int, service: AgentService) throws {
        let index = (step - 1) / ticksPerMessage
        let tick = (step - 1) % ticksPerMessage
        guard index < messages.count else {
            if tick == 0 && index == messages.count {
                service.abandonDialog()
                service.prefillInput("")
                service.isStreaming = true
                service.messages.append(AgentMessage(role: .assistant, blocks: [.text("")]))
            }
            if let last = service.messages.indices.last {
                service.messages[last].blocks = [.text(String(repeating:
                    "Waiting on your verdict. ", count: step % 40 + 1))]
            }
            return
        }
        let message = messages[index]
        if tick == 0 {
            service.abandonDialog()
            service.prefillInput("")
            service.isStreaming = true
            var pending = message
            pending.blocks = []
            service.messages.append(pending)
        }
        let fraction = Double(tick + 1) / Double(ticksPerMessage)
        let position = fraction * Double(message.blocks.count)
        var blocks = Array(message.blocks.prefix(Int(position)))
        if Int(position) < message.blocks.count {
            let progress = position - Double(Int(position))
            switch message.blocks[Int(position)] {
            case .text(let text):
                blocks.append(.text(String(text.prefix(Int(Double(text.count) * progress)))))
            case .toolUse(let id, let name, let inputJSON):
                blocks.append(.toolUse(id: id, name: name,
                                       inputJSON: String(inputJSON.prefix(Int(Double(inputJSON.count) * progress)))))
            default: break
            }
        }
        service.messages[service.messages.count - 1].blocks = blocks
        if tick == ticksPerMessage - 1 {
            for block in message.blocks {
                guard case .toolUse(_, let name, let inputJSON) = block,
                      name == "show_dialog" || name.hasSuffix("__show_dialog") else { continue }
                guard let args = try JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                service.abandonDialog()
                service.isStreaming = false
                try service.presentDialog(AgentDialog.parse(args))
                emit("recorded-dialog-presented", step: step)
            }
        }
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
        guard ProcessInfo.processInfo.environment["NGV_CHAT_REPLAY_FIXTURE"] == nil else { return }
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
