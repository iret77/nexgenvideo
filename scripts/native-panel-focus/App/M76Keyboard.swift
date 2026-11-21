import AppKit

extension PanelProbeDelegate {
    func sendOriginalShortcut(in panel: NSOpenPanel) throws {
        try key(5, "G", modifiers: [.command, .shift], in: panel)
    }

    private func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], in target: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                throw GateBlocked("The native keyboard event could not be created.")
            }
            NSApp.postEvent(event, atStart: false)
        }
    }
}
