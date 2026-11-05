import AppKit
import ApplicationServices
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Native SwiftUI button discovery", .serialized)
@MainActor
struct NativeButtonInteractionTests {
    private typealias Query = NativeButtonAccessibility

    @MainActor private final class Fixture {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)

        init(disabled: Bool = false, duplicate: Bool = false) {
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HStack {
                Button("Undo") {}.disabled(disabled)
                if duplicate { Button("Undo") {} }
                Button("Redo") {}.disabled(true)
            }.buttonStyle(.capsule()))
            window.orderFrontRegardless()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        var request: Query.Request {
            let frame = window.frame
            return Query.Request(pid: getpid(), windowNumber: window.windowNumber,
                windowFrame: .init(CGRect(x: frame.minX,
                    y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
                    width: frame.width, height: frame.height)))
        }

        func ready() async throws -> Query.Snapshot {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var last = await Query.read(request)
            while ProcessInfo.processInfo.systemUptime < deadline {
                if last.complete, last.nodes.contains(where: { $0.role == kAXButtonRole && $0.label == "Undo" }) {
                    return last
                }
                try await Task.sleep(for: .milliseconds(50))
                last = await Query.read(request)
            }
            Issue.record("Native own-process AX query failed: \(last.failure ?? "missing Undo"); \(last.applicationStatuses)")
            return last
        }

        func close() { window.contentView = nil; window.close() }
    }

    @MainActor private final class LastChildRoot: NSView {
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityChildren() -> [Any]? { subviews }
    }

    @MainActor private final class SlowLeaf: NSView {
        let entered = DispatchSemaphore(value: 0)
        var armed = false
        var enteredAt: Double = 0
        var returnedAt: Double = 0

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityChildren() -> [Any]? {
            if armed {
                enteredAt = ProcessInfo.processInfo.systemUptime
                entered.signal()
                Thread.sleep(forTimeInterval: 0.35)
                returnedAt = ProcessInfo.processInfo.systemUptime
            }
            return []
        }
    }

    @MainActor private final class SlowFixture {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let root = LastChildRoot(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let leaf = SlowLeaf(frame: NSRect(x: 20, y: 20, width: 100, height: 40))

        init() {
            window.isReleasedWhenClosed = false
            window.setAccessibilityElement(true)
            window.setAccessibilityTitle("Native bounded AX query")
            leaf.setAccessibilityLabel("Bounded child")
            root.addSubview(leaf)
            let button = NSButton(title: "Undo", target: nil, action: nil)
            button.frame = NSRect(x: 180, y: 20, width: 100, height: 30)
            root.addSubview(button)
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
        }

        var request: Query.Request {
            let frame = window.frame
            return Query.Request(pid: getpid(), windowNumber: window.windowNumber,
                windowFrame: .init(CGRect(x: frame.minX,
                    y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
                    width: frame.width, height: frame.height)))
        }

        func arm() {
            leaf.armed = true
            NSAccessibility.post(element: leaf, notification: .layoutChanged)
        }

        func close() { window.contentView = nil; window.close() }
    }

    private var frame: Query.Frame { .init(CGRect(x: 20, y: 20, width: 50, height: 28)) }
    private var probe: Query.Frame { .init(CGRect(x: 20, y: 20, width: 50, height: 28)) }

    private func node(role: String = kAXButtonRole, label: String? = "Undo", enabled: Bool? = true,
                      frame: Query.Frame? = nil, pid: pid_t? = nil,
                      failure: String? = nil) -> Query.Node {
        var statuses: [String: Int32] = ["pid": 0, kAXRoleAttribute: 0, kAXEnabledAttribute: 0,
            kAXPositionAttribute: 0, kAXSizeAttribute: 0,
            kAXTitleAttribute: AXError.noValue.rawValue,
            kAXDescriptionAttribute: label == nil ? AXError.noValue.rawValue : AXError.success.rawValue]
        if let failure { statuses[failure] = AXError.cannotComplete.rawValue }
        return Query.Node(parent: 0, pid: pid ?? getpid(), role: role, title: nil, label: label,
            enabled: enabled, frame: frame ?? self.frame, statuses: statuses, childTypes: [])
    }

    private func snapshot(_ nodes: [Query.Node]) -> Query.Snapshot {
        var value = Query.Snapshot(request: .init(pid: getpid(), windowNumber: 1,
            windowFrame: .init(CGRect(x: 0, y: 0, width: 600, height: 200))))
        value.nodes = nodes; value.windowCandidates = 1; value.complete = true
        value.reportedWindowCount = 1
        value.windows = [node(role: kAXWindowRole, frame: value.request.windowFrame)]
        value.cgWindows = [.init(pid: getpid(), number: 1, frame: value.request.windowFrame, onscreen: true)]
        return value
    }

    @Test func actualSwiftUIButtonIsDiscoveredWithoutAnExternalReader() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let result = try await fixture.ready()
        #expect(result.complete)
        #expect(result.failure == nil)
        #expect(!result.readOnMainThread)
        #expect(result.finished >= result.started)
        let buttons = Query.buttons(result, title: "Undo", inside: fixture.request.windowFrame)
        let button = try #require(buttons.count == 1 ? buttons.first : nil)
        #expect(button.enabled == true)
        #expect(button.frame?.valid == true)
        #expect(button.pid == getpid())
    }

    @Test func actualDisabledSwiftUIButtonIsExcluded() async throws {
        let fixture = Fixture(disabled: true)
        defer { fixture.close() }
        let result = try await fixture.ready()
        #expect(result.complete)
        #expect(result.nodes.contains { $0.label == "Undo" && $0.enabled == false })
        #expect(Query.buttons(result, title: "Undo", inside: fixture.request.windowFrame).isEmpty)
    }

    @Test func actualDuplicateButtonsCannotBecomeAUniqueTarget() async throws {
        let fixture = Fixture(duplicate: true)
        defer { fixture.close() }
        let result = try await fixture.ready()
        #expect(result.complete)
        #expect(Query.buttons(result, title: "Undo", inside: fixture.request.windowFrame).count == 2)
    }

    @Test func actualTraversalBudgetCannotQualifyAPartialTree() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let complete = try await fixture.ready()
        #expect(complete.complete)
        let bounded = await Query.read(fixture.request, nodeLimit: 1)
        #expect(!bounded.complete)
        #expect(bounded.failure == "AX-node-budget")
        #expect(bounded.nodes.count == 1)
        #expect(Query.buttons(bounded, title: "Undo", inside: fixture.request.windowFrame).isEmpty)
    }

    @Test func ownProcessBoundaryRejectsForeignRequests() async {
        let foreign = Query.Request(pid: getpid() + 1, windowNumber: 1, windowFrame: frame)
        let result = await Query.read(foreign)
        #expect(!result.complete)
        #expect(result.failure == "invalid-owned-window-request")
        #expect(result.nodes.isEmpty)
    }

    @Test func incompleteAndAmbiguousWindowEvidenceCannotSelectAButton() {
        var value = snapshot([node()])
        #expect(Query.buttons(value, title: "Undo", inside: probe).count == 1)
        value.complete = false
        #expect(Query.buttons(value, title: "Undo", inside: probe).isEmpty)
        value.complete = true; value.failure = "query-deadline"
        #expect(Query.buttons(value, title: "Undo", inside: probe).isEmpty)
        value.failure = nil
        for count in [0, 2] {
            value.windowCandidates = count
            #expect(Query.buttons(value, title: "Undo", inside: probe).isEmpty)
        }
    }

    @Test func anUnreadableSecondWindowCannotMakeTheFirstWindowUnique() {
        for attribute in ["pid", kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute] {
            var value = snapshot([node()])
            value.windows.append(node(role: kAXWindowRole, frame: value.request.windowFrame, failure: attribute))
            value.reportedWindowCount = 2
            #expect(Query.buttons(value, title: "Undo", inside: probe).isEmpty)
        }
        var missing = snapshot([node()])
        missing.reportedWindowCount = 2
        #expect(Query.buttons(missing, title: "Undo", inside: probe).isEmpty)
    }

    @Test func anUnreadableSecondButtonCannotMakeTheFirstButtonUnique() {
        for attribute in ["pid", kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                          kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute] {
            let value = snapshot([node(), node(failure: attribute)])
            #expect(Query.buttons(value, title: "Undo", inside: probe).isEmpty)
        }
        #expect(Query.buttons(snapshot([node(), node(enabled: nil)]), title: "Undo", inside: probe).isEmpty)
    }

    @Test func aSecondOwnCGWindowAtTheSameFramePreventsWindowBinding() {
        var value = snapshot([node()])
        #expect(Query.buttons(value, title: "Undo", inside: probe).count == 1)
        value.cgWindows.append(.init(pid: getpid(), number: 2, frame: value.request.windowFrame, onscreen: true))
        #expect(!Query.uniqueCGWindow(value.cgWindows, request: value.request))
        #expect(Query.buttons(value, title: "Undo", inside: probe).isEmpty)
        value.cgWindows = [.init(pid: getpid(), number: 2, frame: value.request.windowFrame, onscreen: true)]
        #expect(Query.buttons(value, title: "Undo", inside: probe).isEmpty)
    }

    @Test func unknownCGMetadataCannotHideACompetingOwnWindow() {
        let value = snapshot([node()])
        let rectangle: [String: Double] = ["X": 0, "Y": 0, "Width": 600, "Height": 200]
        let target: [String: Any] = [kCGWindowOwnerPID as String: getpid(), kCGWindowNumber as String: 1,
            kCGWindowBounds as String: rectangle, kCGWindowIsOnscreen as String: true]
        #expect(Query.uniqueCGWindow(Query.ownCGWindows([target], pid: getpid()), request: value.request))
        for field in [kCGWindowOwnerPID as String, kCGWindowNumber as String,
                      kCGWindowBounds as String, kCGWindowIsOnscreen as String] {
            var unknown = target
            unknown[kCGWindowNumber as String] = 2
            unknown.removeValue(forKey: field)
            let windows = Query.ownCGWindows([target, unknown], pid: getpid())
            #expect(!Query.uniqueCGWindow(windows, request: value.request))
        }
        var malformed = target
        malformed[kCGWindowNumber as String] = 2
        malformed[kCGWindowBounds as String] = ["X": Double.nan, "Y": 0, "Width": 600, "Height": 200]
        #expect(!Query.uniqueCGWindow(Query.ownCGWindows([target, malformed], pid: getpid()), request: value.request))
        malformed = target
        malformed[kCGWindowOwnerPID as String] = getpid() + 1
        #expect(Query.uniqueCGWindow(Query.ownCGWindows([target, malformed], pid: getpid()), request: value.request))
    }

    @Test func roleLabelAndEnabledStateAreIndependentRequirements() {
        for candidate in [node(role: kAXGroupRole), node(label: "Redo"), node(label: nil),
                          node(enabled: false), node(enabled: nil)] {
            #expect(Query.buttons(snapshot([candidate]), title: "Undo", inside: probe).isEmpty)
        }
        #expect(Query.buttons(snapshot([node()]), title: "", inside: probe).isEmpty)
    }

    @Test func failedGeometryOrPIDAttributesCannotSupplyAFrame() {
        for attribute in ["pid", kAXRoleAttribute, kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute] {
            #expect(Query.buttons(snapshot([node(failure: attribute)]), title: "Undo", inside: probe).isEmpty)
        }
        #expect(Query.buttons(snapshot([node(pid: getpid() + 1)]), title: "Undo", inside: probe).isEmpty)
    }

    @Test func nonfiniteEmptyAndOutOfProbeFramesAreRejected() {
        for rect in [CGRect(x: Double.nan, y: 20, width: 50, height: 28),
                     CGRect(x: 20, y: 20, width: 0, height: 28),
                     CGRect(x: 20, y: 20, width: 52, height: 28),
                     CGRect(x: 20, y: 180, width: 50, height: 28)] {
            #expect(Query.buttons(snapshot([node(frame: .init(rect))]), title: "Undo", inside: probe).isEmpty)
        }
    }

    @Test func realDecorationTolerancePreservesTheActualProbeCenter() {
        let decoration = Query.Frame(CGRect(x: 19, y: 19, width: 52, height: 30))
        #expect(Query.buttons(snapshot([node(frame: decoration)]), title: "Undo", inside: probe).count == 1)
        #expect(Query.buttons(snapshot([node(), node()]), title: "Undo", inside: probe).count == 2)
    }

    @Test func cancellationIsRetainedAsAnIncompleteQuery() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let request = fixture.request
        let task = Task { await Query.read(request) }
        task.cancel()
        let result = await task.value
        #expect(!result.complete)
        #expect(result.failure == "cancelled")
    }

    @Test func cancellationDuringTheLastChildMessageCannotQualifyATree() async throws {
        let fixture = SlowFixture()
        defer { fixture.close() }
        let warm = await Query.read(fixture.request)
        try #require(warm.complete)
        try #require(Query.buttons(warm, title: "Undo", inside: fixture.request.windowFrame).count == 1)
        fixture.arm()
        let request = fixture.request, entered = fixture.leaf.entered
        let query = Task.detached { await Query.read(request) }
        let observed: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let observed = entered.wait(timeout: .now() + 2) == .success
                if observed { query.cancel() }
                continuation.resume(returning: observed)
            }
        }
        let result = await query.value
        #expect(observed)
        #expect(result.windowCandidates == 1)
        #expect(fixture.leaf.enteredAt >= result.started)
        #expect(!result.complete)
        #expect(result.failure == "cancelled")
        #expect(result.finished < fixture.leaf.returnedAt)
    }

    @Test func theLastChildMessageUsesItsOwnRemainingTimeout() async throws {
        let fixture = SlowFixture()
        defer { fixture.close() }
        let warm = await Query.read(fixture.request)
        try #require(warm.complete)
        try #require(Query.buttons(warm, title: "Undo", inside: fixture.request.windowFrame).count == 1)
        fixture.arm()
        let result = await Query.read(fixture.request, seconds: 0.2)
        #expect(result.windowCandidates == 1)
        #expect(fixture.leaf.enteredAt >= result.started)
        #expect(fixture.leaf.returnedAt > fixture.leaf.enteredAt)
        #expect(!result.complete)
        #expect(result.finished < fixture.leaf.returnedAt)
        let last = try #require(result.nodes.last { $0.label == "Bounded child" })
        #expect(last.statuses[kAXChildrenAttribute] != AXError.success.rawValue)
        #expect(last.statuses["timeout:" + kAXChildrenAttribute] == AXError.success.rawValue)
    }
}
