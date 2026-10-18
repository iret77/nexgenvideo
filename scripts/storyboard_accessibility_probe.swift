import AppKit
import Darwin
import SwiftUI

private struct Shot: Identifiable {
    let id: String
    let subject: String
    let purpose: String
}

private struct ClickProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> ClickProbeView {
        let view = ClickProbeView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: ClickProbeView, context: Context) {}
}

private final class ClickProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct Storyboard: View {
    let shots: [Shot]

    var body: some View {
        VStack(spacing: 0) {
            Text("Storyboard").frame(maxWidth: .infinity, alignment: .leading).padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Verse 1")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(shots) { shot in
                            Button {} label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(shot.id)
                                        Spacer()
                                        Text("Section · 0.0–12.0 s")
                                    }
                                    Text(shot.subject).font(.headline).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(shot.purpose).lineLimit(1)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                                .background(Color.gray.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(shot.id), \(shot.subject), 0.0–12.0 s")
                            .background {
                                ClickProbe(identifier: "storyboard.shot.\(shot.id)")
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Storyboard · Upcoming").frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}

private final class PanelHost<Content: View>: NSViewController {
    private let hosting: NSHostingController<Content>

    init(content: Content, identifier: String) {
        hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
        view.setAccessibilityIdentifier(identifier)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        addChild(hosting)
        view.addSubview(hosting.view)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        hosting.view.frame = view.bounds.insetBy(dx: 2, dy: 2)
    }
}

@main
@MainActor
private enum StoryboardAccessibilityProbe {
    private struct Failure: Error { let message: String }

    private enum Scan: String, CaseIterable {
        case original, publicContainers, legacyAttributes
    }

    private struct Read {
        var text: [String] = []
        var nodes: [[String: Any]] = []
        var truncated = false
        var visited = Set<ObjectIdentifier>()

        var json: [String: Any] {
            ["text": text, "nodes": nodes, "nodeCount": visited.count, "truncated": truncated]
        }
    }

    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            var report: [String: Any] = ["schema": "storyboard-accessibility-probe/v1", "measurementOnly": true,
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "finished": false]
            do {
                guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else {
                    throw Failure(message: "The probe requires macOS 26.")
                }
                report.merge(try await measure()) { _, new in new }
                report["finished"] = true
                try write(report, to: destination)
                exit(report["textVerified"] as? Bool == true ? 0 : 2)
            } catch {
                report["error"] = (error as? Failure)?.message ?? error.localizedDescription
                try? write(report, to: destination)
                exit(2)
            }
        }
        app.run()
    }

    private static func measure() async throws -> [String: Any] {
        let shots = [Shot(id: "verse1.01", subject: "The singer stops at the platform edge.", purpose: "Story"),
            Shot(id: "verse1.02", subject: "A train passes the empty platform.", purpose: "Transition"),
            Shot(id: "chorus1.01", subject: "The singer turns toward the morning light.", purpose: "Performance")]
        let expected = ["The singer stops at the platform edge.", "A train passes the empty platform.",
            "The singer turns toward the morning light."]
        let forbidden = ["basis: inferred", "angle:", "height:", "lens_hint:",
            "generated", "transition", "performance", "wide.noon"]
        let root = NSViewController()
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 650))
        let artifact = PanelHost(content: Storyboard(shots: shots), identifier: "projectPanel")
        let inspector = PanelHost(content: ScrollView {
            VStack(alignment: .leading) {
                Text("Inspector control text")
                Text("Independent selectable text")
            }.padding(12).textSelection(.enabled)
        }, identifier: "inspectorPanel")
        for child in [artifact as NSViewController, inspector as NSViewController] {
            root.addChild(child)
            root.view.addSubview(child.view)
        }
        artifact.view.frame = NSRect(x: 0, y: 0, width: 460, height: 650)
        inspector.view.frame = NSRect(x: 470, y: 0, width: 330, height: 650)
        let window = NSWindow(contentRect: root.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var probes: [NSView] = []
        while ContinuousClock.now < deadline {
            root.view.layoutSubtreeIfNeeded()
            probes = descendants(artifact.view).filter { $0 is ClickProbeView }
            if probes.count == 3, probes.allSatisfy({ !$0.isHiddenOrHasHiddenAncestor
                && $0.bounds.width > 0 && $0.bounds.height > 0
                && artifact.view.bounds.contains($0.convert($0.bounds, to: artifact.view)) }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard probes.count == 3, probes.allSatisfy({ !$0.isHiddenOrHasHiddenAncestor
            && $0.bounds.width > 0 && $0.bounds.height > 0
            && artifact.view.bounds.contains($0.convert($0.bounds, to: artifact.view)) }) else {
            throw Failure(message: "The three synthetic cards did not become fully visible.")
        }
        var samples: [[String: Any]] = []
        var hits: [[String: Any]] = []
        var verified = false
        for checkpoint in ["beforeHitTest", "afterHitTest", "afterRunLoop"] {
            if checkpoint == "afterHitTest" {
                hits = probes.map { probe in
                    let center = probe.convert(NSPoint(x: probe.bounds.midX, y: probe.bounds.midY), to: nil)
                    let screenPoint = window.convertPoint(toScreen: center)
                    let hit = artifact.view.accessibilityHitTest(screenPoint)
                    var ancestry: [[String: Any]] = []
                    var ancestor: NSView? = probe
                    while let view = ancestor {
                        ancestry.append(["class": className(view), "identifier": (view.accessibilityIdentifier() as String?) ?? "",
                            "frameInWindow": rect(view.convert(view.bounds, to: nil)),
                            "hidden": view.isHiddenOrHasHiddenAncestor])
                        if view === artifact.view { break }
                        ancestor = view.superview
                    }
                    return ["probe": probe.identifier?.rawValue ?? "", "nativeAncestry": ancestry,
                        "hitClass": hit.map { String(reflecting: type(of: $0)) } ?? "none",
                        "hitAccessibilityAncestry": hit.map(accessibilityAncestry) ?? [],
                        "hitPublicTree": hit.map { scan($0, mode: .publicContainers).json } ?? [:],
                        "hitLegacyTree": hit.map { scan($0, mode: .legacyAttributes).json } ?? [:]]
                }
            } else if checkpoint == "afterRunLoop" {
                try await Task.sleep(for: .milliseconds(200))
                root.view.layoutSubtreeIfNeeded()
            }
            var sample: [String: Any] = ["checkpoint": checkpoint]
            for mode in Scan.allCases {
                let read = scan(artifact.view, mode: mode)
                let text = read.text.joined(separator: "\n")
                let missing = expected.filter { !text.contains($0) }
                let leaked = forbidden.filter { text.contains($0) }
                var result = read.json
                result["missingSubjects"] = missing
                result["leakedTokens"] = leaked
                result["allSubjectsVerified"] = missing.isEmpty && leaked.isEmpty && !read.truncated
                sample[mode.rawValue] = result
                if mode != .original, missing.isEmpty, leaked.isEmpty, !read.truncated { verified = true }
            }
            sample["inspectorOriginal"] = scan(inspector.view, mode: .original).json
            samples.append(sample)
        }
        return ["samples": samples, "hits": hits, "textVerified": verified,
            "expectedSubjects": expected, "forbiddenTokens": forbidden,
            "artifactClass": className(artifact.view), "artifactFrame": rect(artifact.view.frame)]
    }

    private static func scan(_ root: Any, mode: Scan) -> Read {
        var result = Read()
        func visit(_ value: Any, edge: String, depth: Int) {
            guard let object = value as? NSObject else {
                result.nodes.append(["class": String(reflecting: type(of: value)), "edge": edge,
                    "unsupportedObject": true])
                return
            }
            guard !result.visited.contains(ObjectIdentifier(object)) else { return }
            guard result.visited.count < 2_000, depth < 64 else { result.truncated = true; return }
            result.visited.insert(ObjectIdentifier(object))
            var node: [String: Any] = ["class": className(object), "edge": edge, "depth": depth]
            var strings: [String] = []
            var edges: [(String, [Any])] = []
            for property in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
                let selector = NSSelectorFromString(property)
                guard object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() else { continue }
                if let text = value as? String, !text.isEmpty { strings.append(text) }
                else if mode != .original, let text = value as? NSAttributedString, !text.string.isEmpty {
                    strings.append(text.string)
                }
            }
            let relationships = mode == .original ? ["accessibilityChildren"] :
                ["accessibilityChildren", "accessibilityChildrenInNavigationOrder", "accessibilityContents", "accessibilityVisibleChildren"]
            for property in relationships {
                let selector = NSSelectorFromString(property)
                guard object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() else { continue }
                if mode == .original {
                    if let children = value as? [NSObject] { edges.append((property, children)) }
                } else if let children = value as? [Any] { edges.append((property, children)) }
            }
            if mode == .legacyAttributes {
                let attributes = object.accessibilityAttributeNames()
                node["legacyAttributes"] = attributes.map(\.rawValue)
                for name in ["AXDescription", "AXValue", "AXTitle", "AXChildren", "AXContents", "AXChildrenInNavigationOrder", "AXVisibleChildren"] {
                    let attribute = NSAccessibility.Attribute(rawValue: name)
                    guard attributes.contains(attribute), let value = object.accessibilityAttributeValue(attribute) else { continue }
                    if let text = value as? String, !text.isEmpty { strings.append(text) }
                    else if let text = value as? NSAttributedString, !text.string.isEmpty { strings.append(text.string) }
                    else if let children = value as? [Any] { edges.append((name, children)) }
                }
            }
            node["text"] = strings
            node["children"] = Dictionary(uniqueKeysWithValues: edges.map { ($0.0, $0.1.count) })
            result.nodes.append(node)
            result.text.append(contentsOf: strings)
            for (edge, children) in edges { children.forEach { visit($0, edge: edge, depth: depth + 1) } }
            (object as? NSView)?.subviews.forEach { visit($0, edge: "subviews", depth: depth + 1) }
        }
        visit(root, edge: "root", depth: 0)
        return result
    }

    private static func write(_ report: [String: Any], to destination: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .atomic)
    }

    private static func accessibilityAncestry(_ hit: Any) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var visited = Set<ObjectIdentifier>()
        var current = hit as? NSObject
        while let object = current, rows.count < 64, visited.insert(ObjectIdentifier(object)).inserted {
            rows.append(["class": className(object)])
            let parent = NSSelectorFromString("accessibilityParent")
            current = object.responds(to: parent)
                ? object.perform(parent)?.takeUnretainedValue() as? NSObject : nil
            if current == nil {
                let attribute = NSAccessibility.Attribute(rawValue: "AXParent")
                if object.accessibilityAttributeNames().contains(attribute) {
                    current = object.accessibilityAttributeValue(attribute) as? NSObject
                }
            }
        }
        return rows
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func className(_ object: NSObject) -> String { NSStringFromClass(type(of: object)) }
    private static func rect(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }
}
