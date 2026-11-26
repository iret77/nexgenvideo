import AppKit
import AVFoundation
import AVKit
import NexGenEngine

@MainActor
enum ProductionNativePlayerAcceptance {
    static func playWholeTake(duration: Double, driver: ProductionVisualSourcesDriver, sheet: NSWindow,
                              playerID id: String = "take.preview.player", recordLabel: String = "complete native take playback") async throws {
        try await driver.reveal(id, in: sheet)
        try driver.visible([id], in: sheet)
        guard let playerView = ProductionNativePlaybackAcceptance.playerView(id, in: sheet), let player = playerView.player,
              let frame = WorkspaceUIAcceptance.probeFrame(identifier: id, in: sheet),
              let root = sheet.contentView, let screen = NSScreen.screens.first else {
            throw GateBlocked("The candidate's actual native player is unavailable.")
        }
        try await driver.wait("whole take decoder ready") { player.currentItem?.status == .readyToPlay }
        guard player.currentTime().seconds < 0.05, player.rate == 0 else {
            throw GateBlocked("The take was already playing before native input.")
        }
        do {
            let transaction = try NativeAcceptancePointer.claim()
            defer { NativeAcceptancePointer.release(transaction) }
            let hover = sheet.convertToScreen(root.convert(NSRect(x: frame.midX, y: frame.midY, width: 0, height: 0), to: nil)).origin
            _ = try await NativeAcceptancePointer.move(to: CGPoint(x: hover.x, y: screen.frame.maxY - hover.y),
                                                       window: sheet, token: transaction) { evidence in
                try driver.record("native player hover", fields: evidence)
            }
        }
        // AX IPC to the own process cannot be served from the main thread, and sheets are absent from AXWindows.
        let playerScreen = sheet.convertToScreen(playerView.convert(playerView.bounds, to: nil))
        var controls: [NSRect] = [], observed: [[String: Any]] = []
        func recordControls() throws {
            try driver.record("native player Play control", fields: ["playerID": id, "elements": observed,
                "playerScreenFrame": [playerScreen.minX, playerScreen.minY, playerScreen.width, playerScreen.height]])
        }
        do {
            try await driver.wait("actual AVPlayer Play control") {
                (controls, observed) = playControls(in: playerView, within: playerScreen)
                return controls.count == 1
            }
        } catch {
            try recordControls()
            throw error
        }
        try recordControls()
        guard controls.count == 1, let control = controls.first,
              let fraction = driver.probeFraction(ofScreenRect: control, id, in: sheet) else {
            throw GateBlocked("The native player did not expose one visible Play control.")
        }
        try await driver.click(id, in: sheet, fraction: fraction)
        try await driver.wait("whole candidate actually playing") { player.rate > 0 && player.currentTime().seconds > 0 }
        try driver.capture("whole-take-playing", target: sheet)
        try await driver.wait("whole candidate reached its last frame", seconds: duration + 5) {
            player.rate == 0 && player.currentTime().seconds >= duration - 0.05
        }
        try driver.record(recordLabel, fields: ["playerID": id, "input": "nativePointer",
            "control": "Play", "controlFrame": [control.minX, control.minY, control.width, control.height],
            "observedSeconds": player.currentTime().seconds, "expectedSeconds": duration])
    }

    private static func playControls(in playerView: AVPlayerView, within player: NSRect) -> ([NSRect], [[String: Any]]) {
        var pending: [any NSAccessibilityProtocol] = [playerView], visited = Set<ObjectIdentifier>()
        var matches: [NSRect] = [], observed: [[String: Any]] = []
        while let element = pending.popLast(), visited.count < 256 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let role = element.accessibilityRole()?.rawValue ?? "", frame = element.accessibilityFrame()
            let label = element.accessibilityLabel() ?? "", title = element.accessibilityTitle() ?? ""
            let enabled = element.isAccessibilityEnabled()
            observed.append(["role": role, "class": String(describing: type(of: element)), "label": label, "title": title,
                             "enabled": enabled, "screenFrame": [frame.minX, frame.minY, frame.width, frame.height]])
            // macOS 27 AVKit exposes Play as a toggle labelled "play".
            let playable = [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.checkBox.rawValue].contains(role)
            if playable, enabled, [label, title].contains(where: { $0.lowercased() == "play" }),
               frame.width > 0, frame.height > 0, player.insetBy(dx: -1, dy: -1).contains(frame) { matches.append(frame) }
            pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        return (matches, observed)
    }
}
