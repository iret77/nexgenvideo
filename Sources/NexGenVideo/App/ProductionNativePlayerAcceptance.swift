import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ProductionNativePlayerAcceptance {
    static func playWholeTake(duration: Double, driver: ProductionVisualSourcesDriver, sheet: NSWindow,
                              playerID id: String = "take.preview.player", recordLabel: String = "complete native take playback") async throws {
        try await driver.reveal(id, in: sheet)
        try driver.visible([id], in: sheet)
        guard let player = ProductionNativePlaybackAcceptance.player(id, in: sheet),
              let frame = WorkspaceUIAcceptance.probeFrame(identifier: id, in: sheet),
              let root = sheet.contentView, let screen = NSScreen.screens.first else {
            throw GateBlocked("The candidate's actual native player is unavailable.")
        }
        try await driver.wait("whole take decoder ready") { player.currentItem?.status == .readyToPlay }
        guard player.currentTime().seconds < 0.05, player.rate == 0 else {
            throw GateBlocked("The take was already playing before native input.")
        }
        let transaction = try NativeAcceptancePointer.claim()
        defer { NativeAcceptancePointer.release(transaction) }
        let hover = sheet.convertToScreen(root.convert(NSRect(x: frame.midX, y: frame.midY, width: 0, height: 0), to: nil)).origin
        _ = try await NativeAcceptancePointer.move(to: CGPoint(x: hover.x, y: screen.frame.maxY - hover.y),
                                                   window: sheet, token: transaction) { evidence in
            try driver.record("native player hover", fields: evidence)
        }
        // The peer reader answers AX queries; an in-process query on the main thread cannot be served.
        var match: (frames: [NSRect], evidence: [String: Any]) = ([], [:])
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            match = await driver.publicButtonWindowFrames(id, title: "Play", in: sheet)
            if match.frames.count == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try driver.record("native player Play control", fields: match.evidence)
        guard match.frames.count == 1, let control = match.frames.first else {
            throw GateBlocked("The native player did not expose one visible Play control.")
        }
        let point = NSPoint(x: control.midX, y: control.midY)
        guard root.hitTest(root.convert(root.convert(point, from: nil), to: root.superview)) != nil else { throw GateBlocked("The native Play control is occluded.") }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw GateBlocked("The native Play pointer event could not be created.")
            }
            NSApp.postEvent(event, atStart: false)
        }
        try await driver.wait("whole candidate actually playing") { player.rate > 0 && player.currentTime().seconds > 0 }
        try driver.capture("whole-take-playing", target: sheet)
        try await driver.wait("whole candidate reached its last frame", seconds: duration + 5) {
            player.rate == 0 && player.currentTime().seconds >= duration - 0.05
        }
        try driver.record(recordLabel, fields: ["playerID": id, "input": "nativePointer",
            "control": "Play", "controlFrame": [control.minX, control.minY, control.width, control.height],
            "observedSeconds": player.currentTime().seconds, "expectedSeconds": duration])
    }
}
