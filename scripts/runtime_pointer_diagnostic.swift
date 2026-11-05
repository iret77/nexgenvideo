import AppKit
import Darwin
import SwiftUI

@MainActor
private final class PointerState: NSObject {
    var count = 0
    var callbackUptimes: [Double] = []
    var probe: NSView?
    var events: [[String: Any]] = []
    var release: PointerRelease?
    var releaseTimer: Timer?
    func activated() {
        count += 1
        callbackUptimes.append(ProcessInfo.processInfo.systemUptime)
    }
    @objc func changed(_ sender: NSButton) { activated() }
}

private struct PointerProbe: NSViewRepresentable {
    let state: PointerState
    func makeNSView(context: Context) -> NSView {
        let view = PointerProbeView()
        state.probe = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
private final class PointerProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class PointerRelease: NSObject {
    var event: NSEvent?
    var quartz: CGPoint?
    var postedUptime: Double?
    @objc func post(_ timer: Timer) {
        if let event {
            postedUptime = ProcessInfo.processInfo.systemUptime
            NSApp.postEvent(event, atStart: false)
        }
        if let quartz, let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                       mouseCursorPosition: quartz, mouseButton: .left) {
            postedUptime = ProcessInfo.processInfo.systemUptime
            up.post(tap: .cghidEventTap)
        }
    }
    func schedule() -> Timer {
        let timer = Timer(timeInterval: 0.03, target: self, selector: #selector(post(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        return timer
    }
}

private struct PointerFixture: View {
    let state: PointerState
    let kind: String
    let frame: CGRect
    let windowSize: CGSize
    var body: some View {
        ZStack(alignment: .topLeading) {
            AppTheme.Background.surfaceColor
            if kind == "undo" {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Undo") { state.activated() }
                        .fixedSize(horizontal: true, vertical: false)
                        .background { PointerProbe(state: state).allowsHitTesting(false) }
                    Button("Redo") {}.disabled(true).fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.capsule())
                .fixedSize()
                .offset(x: frame.minX, y: frame.minY)
            } else {
                ScrollView {
                    Button("Apply transform") { state.activated() }
                        .buttonStyle(.capsule(size: .regular))
                        .background { PointerProbe(state: state).allowsHitTesting(false) }
                }
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
        .environment(\.interfaceScale, AppTheme.Typography.standardScale)
        .environment(\.projectPalette, .neutral)
        .preferredColorScheme(.dark)
    }
}

@main
@MainActor
private struct RuntimePointerDiagnostic {
    static func rectangle(_ rect: NSRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }

    static func pause(_ nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }

    static func accessibility(_ view: NSView, title: String, budget: Int = 2048) -> [String: Any] {
        var pending: [any NSAccessibilityProtocol] = [view]
        var seen = Set<ObjectIdentifier>()
        var rows: [[String: Any]] = []
        while !pending.isEmpty && seen.count < budget {
            guard let element = pending.popLast() else { break }
            guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
            let label = element.accessibilityLabel() ?? ""
            let name = element.accessibilityTitle() ?? ""
            if label == title || name == title {
                rows.append(["class": String(reflecting: type(of: element)), "label": label, "title": name,
                    "help": element.accessibilityHelp() ?? "", "role": element.accessibilityRole()?.rawValue ?? "",
                    "frame": rectangle(element.accessibilityFrame()), "enabled": element.isAccessibilityEnabled()])
            }
            pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        return ["targets": rows, "visitedCount": seen.count, "budget": budget, "traversalComplete": pending.isEmpty]
    }

    static func verifyAccessibilityBudget(output: URL) throws {
        let root = NSView(), child = NSView()
        root.setAccessibilityElement(true)
        child.setAccessibilityElement(true)
        root.setAccessibilityChildren([child])
        child.setAccessibilityChildren([])
        let limited = accessibility(root, title: "", budget: 1)
        let complete = accessibility(root, title: "", budget: 2)
        let result = ["limited": limited, "complete": complete]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("accessibility-budget-regression.json"), options: .atomic)
        guard limited["visitedCount"] as? Int == 1, limited["traversalComplete"] as? Bool == false,
              complete["visitedCount"] as? Int == 2, complete["traversalComplete"] as? Bool == true else {
            throw CocoaError(.coderInvalidValue)
        }
    }

    static func observe(root: NSView, window: NSWindow, state: PointerState, frame: NSRect, title: String) -> [String: Any] {
        let point = NSPoint(x: frame.midX, y: root.bounds.height - frame.midY)
        let local = root.convert(point, from: nil)
        let parentPoint = root.convert(local, to: root.superview)
        let hit = root.hitTest(parentPoint)
        let probeFrame = state.probe.map { $0.convert($0.bounds, to: nil) }
        let topFrame = state.probe.map { probe -> NSRect in
            let rect = probe.convert(probe.bounds, to: root)
            return root.isFlipped ? rect : NSRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let color = AppTheme.Text.secondary.usingColorSpace(.sRGB)
        let originalWindowFrame = NSRect(x: frame.minX, y: root.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        let screenFrame = window.convertToScreen(originalWindowFrame)
        var measuredStyle: [String: Any] = ["paintedFont": NSNull(), "paintedForeground": NSNull(),
            "internalStyleHoverState": NSNull(), "physicalCursorInsideOriginalTarget": screenFrame.contains(NSEvent.mouseLocation)]
        if let button = state.probe as? NSButton, let font = button.font {
            measuredStyle["nativeFontProperty"] = ["pointSize": font.pointSize, "fontName": font.fontName,
                "descriptorTraits": String(describing: font.fontDescriptor.object(forKey: .traits))]
        }
        var configuredStyle: [String: Any] = [:]
        if !(state.probe is NSButton) {
            configuredStyle = ["fontPointSize": AppTheme.Typography.action, "fontWeight": "medium",
                "foreground": color.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] } ?? []]
        }
        return ["callbackCount": state.count, "callbackUptimes": state.callbackUptimes,
            "windowIsKey": window.isKeyWindow, "windowIsVisible": window.isVisible,
            "contentBounds": rectangle(root.bounds), "windowPoint": [point.x, point.y],
            "rootPoint": [local.x, local.y], "hitTestSuperviewPoint": [parentPoint.x, parentPoint.y],
            "rootFrame": rectangle(root.frame), "rootIsFlipped": root.isFlipped,
            "superviewFrame": root.superview.map { rectangle($0.frame) } ?? [],
            "superviewIsFlipped": root.superview?.isFlipped ?? false,
            "hitClass": hit.map { String(reflecting: type(of: $0)) } ?? "nil",
            "firstResponder": window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil",
            "probeWindowFrame": probeFrame.map(rectangle) ?? [], "probeTopFrame": topFrame.map(rectangle) ?? [],
            "probeHidden": state.probe?.isHiddenOrHasHiddenAncestor ?? true,
            "originalScreenFrame": rectangle(screenFrame), "ax": accessibility(root, title: title),
            "screenCursor": [NSEvent.mouseLocation.x, NSEvent.mouseLocation.y],
            "configuredSwiftUIStyle": configuredStyle,
            "measuredStyle": measuredStyle,
            "interfaceScale": AppTheme.Typography.standardScale]
    }

    static func send(route: String, point: NSPoint, window: NSWindow, state: PointerState) async throws -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        if route == "hid" {
            let screen = window.convertPoint(toScreen: point)
            guard let display = NSScreen.screens.first else { throw CocoaError(.coderInvalidValue) }
            let quartz = CGPoint(x: screen.x, y: display.frame.maxY - screen.y)
            guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: quartz, mouseButton: .left),
                  let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: quartz, mouseButton: .left) else {
                throw CocoaError(.coderInvalidValue)
            }
            move.post(tap: .cghidEventTap)
            try await pause(100_000_000)
            let downTime = ProcessInfo.processInfo.systemUptime
            let release = PointerRelease()
            release.quartz = quartz
            state.release = release
            down.post(tap: .cghidEventTap)
            try await pause(100_000_000)
            state.releaseTimer?.invalidate()
            return ["downPostedUptime": downTime, "upPostedUptime": release.postedUptime.map { $0 as Any } ?? NSNull(),
                    "enqueueDurationSeconds": NSNull(), "syntheticTimestampDeltaSeconds": NSNull(), "cursorMovePosted": true]
        }
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: start, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: start + (route == "queued" ? 0.001 : 0.03), windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { throw CocoaError(.coderInvalidValue) }
        if route == "queued" {
            let downTime = ProcessInfo.processInfo.systemUptime
            NSApp.postEvent(down, atStart: false)
            let upTime = ProcessInfo.processInfo.systemUptime
            NSApp.postEvent(up, atStart: false)
            return ["downPostedUptime": downTime, "upPostedUptime": upTime,
                    "enqueueDurationSeconds": ProcessInfo.processInfo.systemUptime - downTime,
                    "syntheticTimestampDeltaSeconds": 0.001, "cursorMovePosted": false]
        }
        let release = PointerRelease()
        release.event = up
        state.release = release
        let downTime = ProcessInfo.processInfo.systemUptime
        NSApp.postEvent(down, atStart: false)
        try await pause(100_000_000)
        state.releaseTimer?.invalidate()
        return ["downPostedUptime": downTime, "upPostedUptime": release.postedUptime.map { $0 as Any } ?? NSNull(),
                "enqueueDurationSeconds": NSNull(), "syntheticTimestampDeltaSeconds": 0.03, "cursorMovePosted": false]
    }

    static func measure(spec: [String: Any], output: URL) async throws {
        try verifyAccessibilityBudget(output: output)
        guard let controls = spec["controls"] as? [String: [String: Any]],
              spec["windowSize"] as? [Int] == [960, 640], spec["interfaceScale"] as? Int == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var samples: [[String: Any]] = []
        for kind in ["undo", "apply", "native"] {
            let key = kind == "apply" ? "spatial.transform.apply" : "spatial.undo"
            guard let values = controls[key]?["frame"] as? [NSNumber], values.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
            let frame = NSRect(x: values[0].doubleValue, y: values[1].doubleValue,
                width: values[2].doubleValue, height: values[3].doubleValue)
            for route in ["queued", "separated", "hid"] {
                let state = PointerState()
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "Pointer delivery measurement"
                if kind == "native" {
                    let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
                    let button = NSButton(title: "Undo", target: state, action: #selector(PointerState.changed(_:)))
                    button.frame = NSRect(x: frame.minX, y: 640 - frame.maxY, width: frame.width, height: frame.height)
                    root.addSubview(button)
                    state.probe = button
                    window.contentView = root
                } else {
                    window.contentView = NSHostingView(rootView: PointerFixture(state: state, kind: kind, frame: frame,
                        windowSize: CGSize(width: 960, height: 640)))
                }
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await pause(300_000_000)
                guard let root = window.contentView, state.probe != nil else { throw CocoaError(.coderInvalidValue) }
                root.layoutSubtreeIfNeeded()
                let monitoredWindow = window.windowNumber
                let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                    let number = event.windowNumber, type = event.type, point = event.locationInWindow, timestamp = event.timestamp
                    MainActor.assumeIsolated {
                        if number == monitoredWindow {
                            state.events.append(["type": type.rawValue, "timestamp": timestamp,
                                "observedUptime": ProcessInfo.processInfo.systemUptime, "point": [point.x, point.y]])
                            if type == .leftMouseDown { state.releaseTimer = state.release?.schedule() }
                        }
                    }
                    return event
                }
                let title = kind == "apply" ? "Apply transform" : "Undo"
                let before = observe(root: root, window: window, state: state, frame: frame, title: title)
                let delivery = try await send(route: route, point: NSPoint(x: frame.midX, y: 640 - frame.midY), window: window, state: state)
                try await pause(300_000_000)
                let after = observe(root: root, window: window, state: state, frame: frame, title: title)
                if let monitor { NSEvent.removeMonitor(monitor) }
                let downTime = state.events.first(where: { $0["type"] as? UInt == NSEvent.EventType.leftMouseDown.rawValue })?["observedUptime"] as? Double
                let upTime = state.events.first(where: { $0["type"] as? UInt == NSEvent.EventType.leftMouseUp.rawValue })?["observedUptime"] as? Double
                let interval = downTime.flatMap { down in upTime.map { $0 - down } }
                guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw CocoaError(.coderInvalidValue) }
                root.cacheDisplay(in: root.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else { throw CocoaError(.coderInvalidValue) }
                let screenshot = kind + "-" + route + ".png"
                try png.write(to: output.appendingPathComponent(screenshot), options: .atomic)
                samples.append(["control": kind, "route": route, "originalFrame": rectangle(frame),
                    "before": before, "after": after, "delivery": delivery, "events": state.events,
                    "configuredVariant": kind == "native" ? "native-system" : "secondary",
                    "configuredSize": kind == "native" ? "native-system" : kind == "apply" ? "regular" : "small",
                    "callbackObserved": state.count == 1, "localMonitorPairComplete": downTime != nil && upTime != nil,
                    "localMonitorLimitation": "Nested control tracking may consume Up without local monitoring",
                    "observedDownUpIntervalSeconds": interval.map { $0 as Any } ?? NSNull(),
                    "screenshot": screenshot, "screenshotPixels": [bitmap.pixelsWide, bitmap.pixelsHigh]])
                let interim: [String: Any] = ["schema": "nexgenvideo/runtime-pointer-measurement/1", "samples": samples,
                    "classification": "framework-pointer-reproduction-only", "appAcceptance": false,
                    "originalUndoCause": "INCONCLUSIVE: requires direct App callback evidence", "input": spec,
                    "osVersion": ProcessInfo.processInfo.operatingSystemVersionString]
                try JSONSerialization.data(withJSONObject: interim, options: [.sortedKeys, .prettyPrinted])
                    .write(to: output.appendingPathComponent("pointer-measurement.json"), options: .atomic)
                window.close()
            }
        }
        guard samples.count == 9, samples.filter({ $0["control"] as? String == "native" })
            .allSatisfy({ $0["callbackObserved"] as? Bool == true }) else { throw CocoaError(.coderInvalidValue) }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await measure(spec: spec, output: output)
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
                exit(1)
            }
        }
        NSApp.run()
    }
}
