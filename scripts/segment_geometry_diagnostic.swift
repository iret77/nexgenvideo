import AppKit
import Darwin
import SwiftUI

@MainActor
private final class PickerProbeBox {
    var view: NSView?
}

private struct PickerGeometryProbe: NSViewRepresentable {
    let box: PickerProbeBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct PickerGeometryFixture: View {
    let box: PickerProbeBox
    @State private var locations = false
    var body: some View {
        Picker("Production Design view", selection: $locations) {
            Text("Design").tag(false)
            Text("Locations · 3D").tag(true)
        }.pickerStyle(.segmented).background { PickerGeometryProbe(box: box).allowsHitTesting(false) }
    }
}

@MainActor
private final class FlippedSegmentProbe: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SegmentDiagnosticTarget: NSObject {
    @objc func changed(_ sender: NSSegmentedControl) {}
}

@main
@MainActor
private struct SegmentGeometryDiagnostic {
    static func rectangle(_ value: NSRect) -> [Double] {
        [value.minX, value.minY, value.width, value.height]
    }

    static func sample(control: NSSegmentedControl, probe: NSView, window: NSWindow, title: String) -> [[String: Any]] {
        var pending: [any NSAccessibilityProtocol] = [control]
        var visited = Set<ObjectIdentifier>()
        var result: [[String: Any]] = []
        while let element = pending.popLast(), visited.count < 64 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let label = element.accessibilityLabel() ?? ""
            let itemTitle = element.accessibilityTitle() ?? ""
            let frame = element.accessibilityFrame()
            let local = probe.convert(window.convertFromScreen(frame), from: nil)
            let enabled = element.isAccessibilityEnabled()
            var row: [String: Any] = ["class": String(reflecting: type(of: element)), "label": label, "title": itemTitle]
            row["screenFrame"] = rectangle(frame)
            row["localFrame"] = rectangle(local)
            row["accessibilityEnabled"] = enabled
            row["containedByProbe"] = probe.bounds.contains(local)
            row["matchesRequestedTitle"] = [label, itemTitle].contains(title)
            row["currentSegmentElementGuardWouldAccept"] = ObjectIdentifier(element) != ObjectIdentifier(control)
                && [label, itemTitle].contains(title) && frame.width > 0 && frame.height > 0
                && enabled && probe.bounds.contains(local)
            result.append(row)
            pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        return result
    }

    static func measure(control: NSSegmentedControl, probe: NSView, root: NSView, window: NSWindow, kind: String) -> [String: Any] {
        var result: [String: Any] = ["kind": kind, "probeFlipped": probe.isFlipped,
            "probeBounds": rectangle(probe.bounds), "probeFrameInRoot": rectangle(probe.convert(probe.bounds, to: root))]
        result["actualControlBounds"] = rectangle(control.bounds)
        result["actualControlFrameInProbe"] = rectangle(control.convert(control.bounds, to: probe))
        result["controlAXFrame"] = rectangle(control.accessibilityFrame())
        result["controlEnabled"] = control.isEnabled
        result["targetSegmentEnabled"] = control.isEnabled(forSegment: 1)
        result["segmentStyle"] = control.segmentStyle.rawValue
        result["controlClass"] = String(reflecting: type(of: control))
        result["elements"] = sample(control: control, probe: probe, window: window, title: "Locations · 3D")
        return result
    }

    static func descendants(_ view: NSView) -> [NSView] {
        var result = [view]
        for child in view.subviews { result += descendants(child) }
        return result
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let data = try Data(contentsOf: input)
        guard let spec = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frame = spec["probeFrame"] as? [NSNumber], frame.count == 4,
              let parent = spec["controlAXFrame"] as? [NSNumber], parent.count == 4,
              let labels = spec["labels"] as? [String], labels == ["Design", "Locations · 3D"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let probeFrame = NSRect(x: frame[0].doubleValue, y: frame[1].doubleValue,
                                width: frame[2].doubleValue, height: frame[3].doubleValue)
        let controlWidth = CGFloat(parent[2].doubleValue)
        let heights = Set([probeFrame.height, CGFloat(parent[3].doubleValue)]).sorted()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Segment geometry diagnostic"
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        let pickerBox = PickerProbeBox()
        let picker = NSHostingView(rootView: PickerGeometryFixture(box: pickerBox))
        picker.frame = probeFrame
        window.contentView?.addSubview(picker)
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        let target = SegmentDiagnosticTarget()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            do {
                guard let root = window.contentView, window.isVisible else { throw CocoaError(.coderInvalidValue) }
                var samples: [[String: Any]] = []
                picker.isHidden = true
                for flipped in [false, true] {
                    for height in heights {
                        for segmentEnabled in [true, false] {
                            let probe: NSView = flipped ? FlippedSegmentProbe(frame: probeFrame) : NSView(frame: probeFrame)
                            let control = NSSegmentedControl(frame: NSRect(x: probeFrame.width - controlWidth,
                                y: (probeFrame.height - height) / 2, width: controlWidth, height: height))
                            control.segmentCount = labels.count
                            control.target = target
                            control.action = #selector(SegmentDiagnosticTarget.changed(_:))
                            control.isEnabled = true
                            control.selectedSegment = 0
                            for (index, label) in labels.enumerated() {
                                control.setLabel(label, forSegment: index)
                                control.setWidth(controlWidth / CGFloat(labels.count), forSegment: index)
                                control.setEnabled(index == 1 ? segmentEnabled : true, forSegment: index)
                            }
                            root.addSubview(probe)
                            probe.addSubview(control)
                            root.layoutSubtreeIfNeeded()
                            window.displayIfNeeded()
                            samples.append(measure(control: control, probe: probe, root: root, window: window, kind: "direct-appkit"))
                            probe.removeFromSuperview()
                        }
                    }
                }
                picker.isHidden = false
                root.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("direct-segment-geometry.json"), options: .atomic)
                let controls = descendants(picker).compactMap { $0 as? NSSegmentedControl }.filter { candidate in
                    candidate.segmentCount == labels.count
                        && (0..<candidate.segmentCount).map { candidate.label(forSegment: $0) } == labels.map(Optional.some)
                }
                guard controls.count == 1, let control = controls.first, let probe = pickerBox.view,
                      probe.bounds.width > 0, probe.bounds.height > 0 else { throw CocoaError(.coderInvalidValue) }
                samples.append(measure(control: control, probe: probe, root: root, window: window, kind: "swiftui-picker"))
                let result: [String: Any] = ["schema": "nexgenvideo/native-segment-geometry/1",
                    "classification": "platform-control-reproduction-only", "appAcceptance": false,
                    "input": spec, "samples": samples]
                let encoded = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try encoded.write(to: output.appendingPathComponent("segment-geometry.json"), options: .atomic)
                application.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
                exit(1)
            }
        }
        application.run()
    }
}
