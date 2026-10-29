import AppKit
import ApplicationServices
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
        let hover = root.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        guard let move = NSEvent.mouseEvent(with: .mouseMoved, location: hover, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0) else { throw GateBlocked("The player hover event could not be created.") }
        NSApp.postEvent(move, atStart: false)
        let global = sheet.convertToScreen(root.convert(frame, to: nil))
        let axPlayer = CGRect(x: global.minX, y: screen.frame.height - global.maxY, width: global.width, height: global.height)
        var control: CGRect?
        try await driver.wait("actual AVPlayer Play control") { control = playButton(in: axPlayer); return control != nil }
        guard let control else { throw GateBlocked("The native player did not expose one visible Play control.") }
        let screenPoint = NSPoint(x: control.midX, y: screen.frame.height - control.midY)
        let point = sheet.convertPoint(fromScreen: screenPoint)
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

    private static func playButton(in frame: CGRect) -> CGRect? {
        let application = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(application, 1)
        var queue = [application], visited: [AXUIElement] = [], found: [CGRect] = []
        while !queue.isEmpty && visited.count < 512 {
            let element = queue.removeFirst()
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0) as? String }
            if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
               attribute(element, kAXEnabledAttribute) as? Bool == true,
               labels.contains("Play"), let position = attribute(element, kAXPositionAttribute),
               let size = attribute(element, kAXSizeAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
               CFGetTypeID(size) == AXValueGetTypeID() {
                var origin = CGPoint.zero, extent = CGSize.zero
                if AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                   AXValueGetValue(size as! AXValue, .cgSize, &extent) {
                    let candidate = CGRect(origin: origin, size: extent)
                    if candidate.width > 0 && candidate.height > 0 && frame.contains(candidate) { found.append(candidate) }
                }
            }
            queue += attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            queue += attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        }
        return found.count == 1 ? found[0] : nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
}
