import AppKit
import Darwin
import SwiftUI
import ObjectiveC.runtime

@MainActor final class AppRelaunchClickProbeView: NSView {}

@MainActor private enum FixtureState {
    static var marker: AppRelaunchClickProbeView?
    static var scroll: NSScrollView?
}

private struct FixtureView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        let marker = AppRelaunchClickProbeView(frame: NSRect(x: 10.25, y: 20.5, width: 620.75, height: 40.125))
        marker.identifier = NSUserInterfaceItemIdentifier("pointer.field")
        document.addSubview(marker)
        if CommandLine.arguments[2] == "duplicate-probe" {
            let duplicate = AppRelaunchClickProbeView(frame: NSRect(x: 20, y: 80, width: 30, height: 30))
            duplicate.identifier = marker.identifier
            document.addSubview(duplicate)
        }
        scroll.documentView = document
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        FixtureState.marker = marker
        FixtureState.scroll = scroll
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

@MainActor private final class FixtureHosting: NSHostingView<FixtureView> {
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { super.accessibilityHitTest(point) }
}

@main @MainActor private enum PointerObserverSelftest {
    static func identity(_ value: AnyObject?) -> String {
        guard let value else { return "nil" }
        return String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(value).toOpaque()))
    }

    static func rect(_ value: NSRect) -> [Double] {
        [value.minX, value.minY, value.width, value.height]
    }

    static func superclassMethods() -> [String] {
        ["convertRect:toView:", "hitTest:"].map { name in
            let method = class_getMethodImplementation(NSView.self, NSSelectorFromString(name))
            return String(unsafeBitCast(method, to: UInt.self), radix: 16)
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw NSError(domain: "ObserverSelftestArguments", code: 1) }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(domain: "ObserverSelftestOccupied", code: 1)
        }
        let originalSuperclassMethods = superclassMethods()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 480, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = FixtureHosting(rootView: FixtureView())
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        root.layoutSubtreeIfNeeded()
        if CommandLine.arguments[2] == "already-key" {
            guard dlopen(CommandLine.arguments[3], RTLD_NOW | RTLD_LOCAL) != nil else {
                throw NSError(domain: "ObserverSelftestLateLoad", code: 1)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let marker = FixtureState.marker, let scroll = FixtureState.scroll,
              let document = scroll.documentView, marker.window === window else {
            throw NSError(domain: "ObserverSelftestMissingViews", code: 1)
        }
        let clip = scroll.contentView
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
        let expected = document.convert(marker.frame, to: clip)
        let actual = marker.convert(marker.bounds, to: clip)
        guard actual == expected, actual.width > clip.bounds.width else {
            throw NSError(domain: "ObserverSelftestReturnOrDimensions", code: 1)
        }
        let location = marker.convert(NSPoint(x: 5, y: 5), to: root.superview)
        let hit = root.hitTest(location)
        guard hit === marker else { throw NSError(domain: "ObserverSelftestHitReturn", code: 1) }
        let nilHit = root.hitTest(NSPoint(x: -200.5, y: -100.25))
        guard nilHit == nil, superclassMethods() == originalSuperclassMethods else {
            throw NSError(domain: "ObserverSelftestNilOrSuperclass", code: 1)
        }
        let witness: [String: Any] = [
            "schema": "pointer-observer-selftest-witness/v1", "pid": getpid(), "parentPID": getppid(),
            "root": identity(root), "probe": identity(marker), "hit": identity(hit),
            "windowIdentity": identity(window), "window": window.windowNumber, "clip": identity(clip),
            "expectedRect": rect(expected), "returnedRect": rect(actual), "clipBounds": rect(clip.bounds),
            "rootBounds": rect(root.bounds), "returnUnchanged": true, "nilUnchanged": true, "superclassUnchanged": true,
            "superclassMethods": originalSuperclassMethods, "scenario": CommandLine.arguments[2], "diagnosticOnly": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: witness, options: [.sortedKeys])
        try data.write(to: destination, options: .withoutOverwriting)
        window.orderOut(nil)
        window.close()
    }
}
