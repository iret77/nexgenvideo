import SwiftUI

struct ContextClickActivation: NSViewRepresentable {
    var activate: () -> Void

    func makeNSView(context: Context) -> Target {
        Target(activate: activate)
    }

    func updateNSView(_ view: Target, context: Context) {
        view.activate = activate
    }

    static func dismantleNSView(_ view: Target, coordinator: Void) {
        Monitor.shared.remove(view)
    }

    final class Target: NSView {
        var activate: () -> Void

        init(activate: @escaping () -> Void) {
            self.activate = activate
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { Monitor.shared.remove(self) }
            else { Monitor.shared.add(self) }
        }
    }

    @MainActor
    final class Monitor {
        static let shared = Monitor()
        private let targets = NSHashTable<Target>.weakObjects()
        private var eventMonitor: Any?

        func add(_ target: Target) {
            targets.add(target)
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
                guard let target = self?.targets.allObjects.first(where: {
                    $0.window === event.window && !$0.isHiddenOrHasHiddenAncestor
                        && $0.visibleRect.contains($0.convert(event.locationInWindow, from: nil))
                }) else { return event }
                target.activate()
                return event
            }
        }

        func remove(_ target: Target) {
            targets.remove(target)
            if targets.allObjects.isEmpty, let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }
    }
}
