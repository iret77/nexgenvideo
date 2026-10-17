import AppKit
import Darwin
import SwiftUI

private enum ProbeGeometry {
    static let viewport = NSSize(width: 480, height: 560)
    static let rowCount = 80
    static let rowHeight: CGFloat = 40
}

private struct SwiftUIRows: View {
    var body: some View {
        ScrollView {
            VStack {
                ForEach(0..<ProbeGeometry.rowCount, id: \.self) { index in
                    Text("Synthetic row \(index)")
                        .frame(maxWidth: .infinity, minHeight: ProbeGeometry.rowHeight,
                               maxHeight: ProbeGeometry.rowHeight, alignment: .leading)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

private final class FlippedRows: NSView {
    override var isFlipped: Bool { true }
}

private struct AppKitRows: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: ProbeGeometry.viewport))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        let document = FlippedRows(frame: NSRect(x: 0, y: 0, width: ProbeGeometry.viewport.width,
            height: CGFloat(ProbeGeometry.rowCount) * ProbeGeometry.rowHeight))
        document.autoresizingMask = [.width]
        for index in 0..<ProbeGeometry.rowCount {
            let row = NSTextField(labelWithString: "Synthetic row \(index)")
            row.frame = NSRect(x: 0, y: CGFloat(index) * ProbeGeometry.rowHeight,
                               width: ProbeGeometry.viewport.width, height: ProbeGeometry.rowHeight)
            document.addSubview(row)
        }
        scroll.documentView = document
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

@main
@MainActor
private enum ReplayScrollProbe {
    private enum WheelMode: String, CaseIterable {
        case precisePhased, preciseUnphased, lineUnphased
    }

    private struct ProbeFailure: Error {
        let message: String
    }

    @MainActor
    private final class DeliveredEvents {
        var rows: [[String: Any]] = []
    }

    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            var results: [[String: Any]] = []
            do {
                guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else {
                    throw ProbeFailure(message: "The probe requires macOS 26.")
                }
                for native in [false, true] {
                    for hitTesting in [false, true] {
                        for gap in [0, 20] {
                            for mode in WheelMode.allCases {
                                var result: [String: Any] = [
                                    "container": native ? "AppKit" : "SwiftUI",
                                    "allowsHitTesting": hitTesting,
                                    "phaseGapMilliseconds": gap,
                                    "wheelMode": mode.rawValue,
                                    "delivery": "directScrollWheel",
                                ]
                                do {
                                    result.merge(try await measure(native: native, hitTesting: hitTesting,
                                                                   gap: gap, mode: mode)) { _, new in new }
                                    result["measured"] = true
                                } catch {
                                    result["measured"] = false
                                    result["error"] = failureMessage(error)
                                }
                                results.append(result)
                                try write(results, to: destination, finished: false)
                            }
                        }
                    }
                }
                for native in [false, true] {
                    for hitTesting in [false, true] {
                        var result: [String: Any] = ["container": native ? "AppKit" : "SwiftUI",
                            "allowsHitTesting": hitTesting, "phaseGapMilliseconds": 20,
                            "wheelMode": WheelMode.precisePhased.rawValue, "delivery": "CGEvent.postToPid"]
                        do {
                            result.merge(try await measure(native: native, hitTesting: hitTesting,
                                gap: 20, mode: .precisePhased, postToProcess: true)) { _, new in new }
                            result["measured"] = true
                        } catch {
                            result["measured"] = false
                            result["error"] = failureMessage(error)
                        }
                        results.append(result)
                        try write(results, to: destination, finished: false)
                    }
                }
                try write(results, to: destination, finished: true)
                exit(results.allSatisfy { $0["measured"] as? Bool == true } ? 0 : 2)
            } catch {
                try? write(results, to: destination, finished: false, error: failureMessage(error))
                exit(2)
            }
        }
        app.run()
    }

    private static func measure(native: Bool, hitTesting: Bool, gap: Int,
                                mode: WheelMode, postToProcess: Bool = false) async throws -> [String: Any] {
        let content = native ? AnyView(AppKitRows()) : AnyView(SwiftUIRows())
        let host = NSHostingView(rootView: content
            .frame(width: ProbeGeometry.viewport.width, height: ProbeGeometry.viewport.height)
            .allowsHitTesting(hitTesting))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ProbeGeometry.viewport),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let scroll = try await preparedScroll(in: host)
        guard let document = scroll.documentView, let screen = NSScreen.screens.first else {
            throw ProbeFailure(message: "The native scroll document or screen is unavailable.")
        }
        let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await awaitInterior(scroll, host: host)
        let before = snapshot(scroll, host: host)
        let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let screenPoint = window.convertPoint(toScreen: center)
        let location = CGPoint(x: screenPoint.x, y: screen.frame.height - screenPoint.y)
        let wheels = try events(mode: mode, delta: 20, location: location)
        let delivered = DeliveredEvents()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                var record = eventRecord(event, scroll: scroll, window: window)
                record["geometryAtDispatch"] = snapshot(scroll, host: host, layout: false)
                record["targetWindowMatches"] = event.windowNumber == window.windowNumber
                delivered.rows.append(record)
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        var eventRecords: [[String: Any]] = []
        let started = ProcessInfo.processInfo.systemUptime
        for (index, wheel) in wheels.enumerated() {
            if index > 0, gap > 0 { try await Task.sleep(for: .milliseconds(gap)) }
            var record = eventRecord(wheel, scroll: scroll, window: window)
            record["millisecondsFromGestureStart"] = elapsed(since: started)
            record["before"] = snapshot(scroll, host: host, layout: false)
            if postToProcess { wheel.cgEvent?.postToPid(getpid()) }
            else { scroll.scrollWheel(with: wheel) }
            record["immediateAfter"] = snapshot(scroll, host: host, layout: false)
            eventRecords.append(record)
        }
        let finished = ProcessInfo.processInfo.systemUptime
        var measurements: [String: Any] = ["before": before,
            "immediateAfter": snapshot(scroll, host: host), "events": eventRecords,
            "targetWindowNumber": window.windowNumber,
            "targetCenterInWindow": point(center), "cgLocation": point(location),
            "centerHitTestClass": className(host.hitTest(host.convert(center, from: nil)))]
        for mark in [20, 60, 150, 300] {
            let delay = finished + Double(mark) / 1000 - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            var sample = snapshot(scroll, host: host)
            sample["millisecondsAfterGesture"] = elapsed(since: finished)
            measurements["after\(mark)ms"] = sample
        }
        measurements["movedUpAt300ms"] = Double(scroll.contentView.bounds.minY)
            <= (before["originY"] as? Double ?? .infinity) - 1
        measurements["originDeltaAt300ms"] = Double(scroll.contentView.bounds.minY)
            - (before["originY"] as? Double ?? 0)
        measurements["movedAt300ms"] = abs(Double(scroll.contentView.bounds.minY)
            - (before["originY"] as? Double ?? 0)) >= 1
        measurements["receivedEvents"] = delivered.rows
        measurements["receivedEventCount"] = delivered.rows.count
        return measurements
    }

    private static func events(mode: WheelMode, delta: Int32, location: CGPoint) throws -> [NSEvent] {
        let beganDelta = delta.signum()
        return try [(CGScrollPhase.began, beganDelta), (.changed, delta - beganDelta), (.ended, 0)].map { phase, amount in
            guard let event = CGEvent(scrollWheelEvent2Source: nil,
                units: mode == .lineUnphased ? .line : .pixel, wheelCount: 1,
                wheel1: amount, wheel2: 0, wheel3: 0) else {
                throw ProbeFailure(message: "CGEvent construction failed.")
            }
            if mode != .lineUnphased { event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            if mode == .precisePhased {
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            }
            event.location = location
            guard let wheel = NSEvent(cgEvent: event) else {
                throw ProbeFailure(message: "NSEvent construction failed.")
            }
            return wheel
        }
    }

    private static func preparedScroll(in host: NSView) async throws -> NSScrollView {
        for _ in 0..<75 {
            host.layoutSubtreeIfNeeded()
            let candidates = descendants(host).compactMap { $0 as? NSScrollView }
            if candidates.count == 1, let scroll = candidates.first, let document = scroll.documentView,
               abs(scroll.bounds.width - ProbeGeometry.viewport.width) < 1,
               abs(scroll.bounds.height - ProbeGeometry.viewport.height) < 1,
               document.frame.height > scroll.contentView.bounds.height + 120 {
                return scroll
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProbeFailure(message: "A unique scroll view with the declared viewport did not appear.")
    }

    private static func awaitInterior(_ scroll: NSScrollView, host: NSView) async throws {
        var previous: NSRect?
        var stableSamples = 0
        for _ in 0..<75 {
            host.layoutSubtreeIfNeeded()
            let clip = scroll.contentView.bounds
            let bottom = (scroll.documentView?.frame.height ?? 0) - clip.height
            let interior = clip.minY > 60 && clip.minY < bottom - 60
            stableSamples = interior && previous == clip ? stableSamples + 1 : 0
            if stableSamples == 2 { return }
            previous = clip
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProbeFailure(message: "The scroll view did not settle at an interior position.")
    }

    private static func snapshot(_ scroll: NSScrollView, host: NSView, layout: Bool = true) -> [String: Any] {
        if layout { host.layoutSubtreeIfNeeded() }
        return ["originY": Double(scroll.contentView.bounds.minY),
            "scrollClass": className(scroll), "documentClass": className(scroll.documentView),
            "clipClass": className(scroll.contentView), "hostClass": className(host),
            "scrollFrame": rect(scroll.frame), "scrollBounds": rect(scroll.bounds),
            "scrollRectInWindow": rect(scroll.convert(scroll.bounds, to: nil)),
            "clipBounds": rect(scroll.contentView.bounds),
            "documentFrame": scroll.documentView.map { rect($0.frame) } ?? [:],
            "documentBounds": scroll.documentView.map { rect($0.bounds) } ?? [:],
            "documentFlipped": scroll.documentView?.isFlipped ?? false,
            "clipFlipped": scroll.contentView.isFlipped, "scrollFlipped": scroll.isFlipped,
            "windowVisible": scroll.window?.isVisible ?? false,
            "windowOcclusionVisible": scroll.window?.occlusionState.contains(.visible) ?? false,
            "windowOnScreen": scroll.window?.screen != nil,
            "windowIsKey": scroll.window?.isKeyWindow ?? false, "applicationActive": NSApp.isActive,
            "documentVisibleRect": scroll.documentView.map { rect($0.visibleRect) } ?? [:],
            "visible": !(scroll.isHiddenOrHasHiddenAncestor || scroll.visibleRect.isEmpty)]
    }

    private static func eventRecord(_ event: NSEvent, scroll: NSScrollView, window: NSWindow) -> [String: Any] {
        let hit = window.contentView.map { $0.hitTest($0.convert(event.locationInWindow, from: nil)) } ?? nil
        var result: [String: Any] = ["phase": event.phase.rawValue, "momentumPhase": event.momentumPhase.rawValue,
            "deltaY": event.deltaY, "scrollingDeltaY": event.scrollingDeltaY,
            "hasPreciseScrollingDeltas": event.hasPreciseScrollingDeltas,
            "windowNumber": event.windowNumber, "eventWindowNumber": event.window?.windowNumber ?? -1,
            "locationInWindow": point(event.locationInWindow), "timestamp": event.timestamp,
            "currentEventIsEvent": NSApp.currentEvent === event, "hitTestClass": className(hit),
            "targetClass": className(scroll)]
        if let cg = event.cgEvent {
            result["cgPhase"] = cg.getIntegerValueField(.scrollWheelEventScrollPhase)
            result["cgContinuous"] = cg.getIntegerValueField(.scrollWheelEventIsContinuous)
            result["cgDeltaY"] = cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            result["cgPointDeltaY"] = cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            result["cgLocation"] = point(cg.location)
        }
        return result
    }

    private static func write(_ results: [[String: Any]], to destination: URL,
                              finished: Bool, error: String? = nil) throws {
        var report: [String: Any] = ["schema": "native-scroll-probe/v1", "measurementOnly": true,
            "finished": finished, "expectedVariants": 28,
            "allVariantsMeasured": finished && results.count == 28 && results.allSatisfy { $0["measured"] as? Bool == true },
            "measurementNotes": [
                "Direct calls bypass application dispatch; zero monitored events and currentEvent=false are expected.",
                "For postToPid, immediate samples may precede delivery; inspect received events and later snapshots.",
                "Movement is the absolute offset delta; signed delta and flipped geometry describe direction.",
                "Zero postToPid events does not distinguish permission, activation or routing failure.",
            ],
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "variants": results]
        if let error { report["error"] = error }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .atomic)
    }

    private static func failureMessage(_ error: Error) -> String {
        (error as? ProbeFailure)?.message ?? error.localizedDescription
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func className(_ view: NSView?) -> String { view.map { NSStringFromClass(type(of: $0)) } ?? "none" }
    private static func elapsed(since start: TimeInterval) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
    private static func point(_ point: CGPoint) -> [String: Double] { ["x": Double(point.x), "y": Double(point.y)] }
    private static func rect(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }
}
