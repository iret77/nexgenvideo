import AppKit
import ApplicationServices
import Darwin
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

        init(disabled: Bool = false, duplicate: Bool = false, split: Bool = false, rows: Int = 0,
             scroll: Bool = false) {
            window.isReleasedWhenClosed = false
            let controls = HStack {
                Button("Undo") {}.disabled(disabled)
                if duplicate { Button("Undo") {} }
                Button("Redo") {}.disabled(true)
            }.buttonStyle(.capsule())
            if scroll {
                window.contentView = NSHostingView(rootView: VStack {
                    controls
                    LegacyScrollView()
                })
            } else if split {
                window.setContentSize(NSSize(width: 600, height: 450))
                window.contentView = NSHostingView(rootView: HSplitView {
                    VStack {
                        controls
                        ForEach(Array(stride(from: 0, to: rows, by: 6)), id: \.self) { start in
                            HStack {
                                ForEach(start..<min(start + 6, rows), id: \.self) { index in
                                    Button("R\(index)") {}.accessibilityLabel("Readout \(index)")
                                }
                            }
                        }
                    }
                    Text("Preview")
                })
            } else {
                window.contentView = NSHostingView(rootView: controls)
            }
            if split, let visible = window.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                    y: visible.midY - window.frame.height / 2))
            }
            window.orderFrontRegardless()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        var request: Query.Request {
            let frame = window.frame
            let content = window.convertToScreen(window.contentView!.convert(window.contentView!.bounds, to: nil))
            return Query.Request(pid: getpid(), windowNumber: window.windowNumber,
                windowFrame: .init(CGRect(x: frame.minX,
                    y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
                    width: frame.width, height: frame.height)),
                contentFrame: .init(CGRect(x: content.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - content.maxY,
                    width: content.width, height: content.height)))
        }

        func ready(using session: NativeAXPeer.Session) async throws -> Query.Snapshot {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var last = await Query.read(request, using: session)
            while ProcessInfo.processInfo.systemUptime < deadline {
                if last.complete, last.nodes.contains(where: { $0.role == kAXButtonRole && $0.label == "Undo" }) {
                    return last
                }
                try await Task.sleep(for: .milliseconds(50))
                last = await Query.read(request, using: session)
            }
            Issue.record("Native own-process AX query failed: \(last.failure ?? "missing Undo"); \(last.applicationStatuses)")
            return last
        }

        func close() { window.contentView = nil; window.close() }

        func recordGeometry(_ snapshot: Query.Snapshot) throws {
            let geometry: [String: Any] = ["windowFrame": NSStringFromRect(window.frame),
                "contentBounds": NSStringFromRect(window.contentView!.bounds),
                "visibleFrame": window.screen.map { NSStringFromRect($0.visibleFrame) } as Any? ?? NSNull(),
                "contentFittingSize": NSStringFromSize(window.contentView!.fittingSize),
                "snapshot": snapshot.evidence]
            let data = try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys])
            print("Native SplitView AX geometry: " + String(decoding: data, as: UTF8.self))
        }
    }

    private struct LegacyScrollView: NSViewRepresentable {
        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = false
            scroll.scrollerStyle = .legacy
            scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
            return scroll
        }

        func updateNSView(_ view: NSScrollView, context: Context) {}
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
                    width: frame.width, height: frame.height)),
                contentFrame: .init(CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
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
        value.contentCandidates = 1
        value.contentRoots = [node(role: kAXGroupRole, frame: value.request.contentFrame)]
        value.rootRivals = value.contentRoots
        value.reportedRootCount = 1; value.rootInventoryComplete = true
        value.windowAttributes = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute]
        value.windowAttributeStatuses = ["AXAttributeNames": 0, "timeout:AXAttributeNames": 0]
        return value
    }

    @Test func actualReaderExportBindsTheLoadedAppCodeImage() throws {
        #expect(NGVRunNativeAXReaderIfRequested(nil) == -1)
        let image = try NativeAXPeer.Image.current()
        let handle = try #require(dlopen(image.path, RTLD_LAZY | RTLD_LOCAL))
        defer { dlclose(handle) }
        let symbol = try #require(dlsym(handle, "NGVRunNativeAXReaderIfRequested"))
        #expect(try NativeAXPeer.Image.current(address: UnsafeRawPointer(symbol)) == image)
    }

    @Test func actualPreparedReaderProvesItsOwnParentImageAndTrust() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let expected = try NativeAXPeer.Image.current()
        let outcome = try await NativeAXPeer.withSession { session in
            let snapshot = try await fixture.ready(using: session)
            let peer = try #require(snapshot.readerEvidence)
            #expect(peer.owner.pid == getpid())
            #expect(peer.reader.pid != getpid())
            #expect(peer.reader.executable == peer.owner.executable)
            #expect(peer.reader.start > 0 && peer.owner.start > 0)
            #expect(peer.image == expected)
            #expect(peer.trusted)
            #expect(peer.readyAt >= peer.startupStarted)
            #expect(peer.sentAt >= peer.readyAt && peer.deadline > peer.sentAt)
            #expect(peer.receivedAt >= snapshot.finished)
            #expect(snapshot.contentRoots.count == 1 && snapshot.contentCandidates == 1)
        }
        #expect(outcome.1.clean)
        #expect(outcome.1.pid != getpid())
    }

    @Test func missingAmbiguousAndUnreadableContentRootsRemainUnqualified() {
        for count in [0, 2] {
            var value = snapshot([node()]); value.contentCandidates = count
            #expect(Query.buttons(value, title: "Undo", inside: probe).isEmpty)
        }
        var missing = snapshot([node()]); missing.contentRoots = []
        #expect(Query.buttons(missing, title: "Undo", inside: probe).isEmpty)
        missing = snapshot([node()]); missing.rootInventoryComplete = false
        #expect(Query.buttons(missing, title: "Undo", inside: probe).isEmpty)
        missing = snapshot([node()]); missing.reportedRootCount = 2
        #expect(Query.buttons(missing, title: "Undo", inside: probe).isEmpty)
        var rival = snapshot([node()])
        rival.rootRivals += rival.contentRoots; rival.reportedRootCount = 2
        #expect(Query.buttons(rival, title: "Undo", inside: probe).isEmpty)
        rival = snapshot([node()])
        rival.rootRivals.append(node(role: kAXGroupRole, frame: .init(CGRect(x: 10, y: 10, width: 50, height: 50))))
        rival.reportedRootCount = 2
        #expect(Query.buttons(rival, title: "Undo", inside: probe).isEmpty)
        for attribute in ["pid", kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute] {
            var value = snapshot([node()])
            value.rootRivals.append(node(role: kAXGroupRole, frame: value.request.contentFrame, failure: attribute))
            value.reportedRootCount = 2
            #expect(Query.buttons(value, title: "Undo", inside: probe).isEmpty)
        }
    }

    @Test func actualWindowFrameCannotSubstituteForTheContentRoot() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let outcome = try await NativeAXPeer.withSession { session in
            let warm = try await fixture.ready(using: session)
            try #require(warm.complete)
            let request = Query.Request(pid: getpid(), windowNumber: fixture.request.windowNumber,
                windowFrame: fixture.request.windowFrame, contentFrame: fixture.request.windowFrame)
            let rejected = await Query.read(request, using: session)
            #expect(!rejected.complete)
            #expect(rejected.readerEvidence?.trusted == true)
            #expect(Query.buttons(rejected, title: "Undo", inside: fixture.request.contentFrame).isEmpty)
        }
        #expect(outcome.1.clean)
    }

    @Test func completedReplyCannotSurviveDeliveryCancellation() {
        let original = snapshot([node()])
        let cancelled = NativeAXPeer.delivery(original, cancelled: true)
        #expect(!cancelled.complete)
        #expect(cancelled.failure == "peer-delivery-cancelled")
        #expect(cancelled.nodes == original.nodes)
        #expect(cancelled.started == original.started && cancelled.finished == original.finished)
        #expect(Query.buttons(cancelled, title: "Undo", inside: probe).isEmpty)
        #expect(NativeAXPeer.delivery(original, cancelled: false).complete)
    }

    @Test func trailingPartialDuplicateAndFailedPeerOutputCannotBecomeCleanEOF() throws {
        let clean = NativeAXPeer.Pump(limit: 64)
        clean.receive(Data("reply\n".utf8))
        #expect(try clean.line() == Data("reply".utf8))
        clean.finish()
        #expect(clean.successful && clean.consumed)
        for trailing in ["duplicate\n", "partial"] {
            let pump = NativeAXPeer.Pump(limit: 64)
            pump.receive(Data("reply\n".utf8)); _ = try pump.line()
            pump.receive(Data(trailing.utf8)); pump.finish()
            #expect(pump.successful && !pump.consumed)
        }
        let failed = NativeAXPeer.Pump(limit: 1)
        failed.receive(Data("overflow".utf8)); failed.finish()
        #expect(!failed.successful)
        let unreadable = NativeAXPeer.Pump(limit: 64)
        unreadable.finish("read-failure")
        #expect(!unreadable.successful)
    }

    @Test func nestedPeerFieldsCannotBeSilentlyIgnored() throws {
        let request = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot([node()]).request))
        let valid: [String: Any] = ["request": request,
            "owner": ["pid": getpid(), "start": 1, "executable": "/owned"],
            "image": ["path": "/owned", "uuid": "known", "SHA256": "known"]]
        try NativeAXPeer.validateWireShape(valid)
        for key in ["owner", "image", "request"] {
            var changed = valid, nested = try #require(valid[key] as? [String: Any])
            nested["unreviewed"] = true; changed[key] = nested
            #expect(throws: (any Error).self) { try NativeAXPeer.validateWireShape(changed) }
        }
        var changed = valid, nested = try #require(request as? [String: Any])
        var frame = try #require(nested["contentFrame"] as? [String: Any])
        frame["unreviewed"] = true; nested["contentFrame"] = frame; changed["request"] = nested
        #expect(throws: (any Error).self) { try NativeAXPeer.validateWireShape(changed) }
    }

    @Test func actualSwiftUIButtonIsDiscoveredWithoutAnExternalReader() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let outcome = try await NativeAXPeer.withSession { session in
            let result = try await fixture.ready(using: session)
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
        #expect(outcome.1.clean)
    }

    @Test func actualSplitViewKeepsTheEnabledUndoDiscoverable() async throws {
        let fixture = Fixture(split: true, rows: 48)
        defer { fixture.close() }
        let outcome = try await NativeAXPeer.withSession { session in
            let value = try await fixture.ready(using: session)
            try #require(value.complete)
            var splitterNode: Query.Node?
            var undo: [Query.Node] = []
            for node in value.nodes {
                if node.role == kAXSplitterRole && splitterNode == nil { splitterNode = node }
                if node.role == kAXButtonRole && (node.title == "Undo" || node.label == "Undo") {
                    undo.append(node)
                }
            }
            let splitter = try #require(splitterNode)
            #expect(splitter.statuses[kAXChildrenAttribute] == AXError.noValue.rawValue)
            #expect(splitter.childTypes.isEmpty)
            #expect(value.nodes.filter { $0.role == kAXButtonRole }.count >= 50)
            #expect(value.nodes.allSatisfy { $0.statuses["timeout:AXAttributes"] == AXError.success.rawValue })
            let buttons = Query.buttons(value, title: "Undo", inside: fixture.request.contentFrame)
            let visible = fixture.window.screen?.visibleFrame
            let contained = undo.count == 1 && undo[0].frame.map {
                value.request.windowFrame.rect.contains($0.rect)
                    && value.request.contentFrame.rect.contains($0.rect)
            } == true
            if buttons.count != 1 || !contained || visible?.contains(fixture.window.frame) != true {
                try fixture.recordGeometry(value)
            }
            #expect(visible?.contains(fixture.window.frame) == true)
            #expect(contained)
            #expect(buttons.count == 1)
        }
        #expect(outcome.1.clean)
    }

    @Test func actualDisabledSwiftUIButtonIsExcluded() async throws {
        let fixture = Fixture(disabled: true)
        defer { fixture.close() }
        let outcome = try await NativeAXPeer.withSession { session in
            let result = try await fixture.ready(using: session)
            #expect(result.complete)
            #expect(result.nodes.contains { $0.label == "Undo" && $0.enabled == false })
            #expect(Query.buttons(result, title: "Undo", inside: fixture.request.windowFrame).isEmpty)
        }
        #expect(outcome.1.clean)
    }

    @Test func actualDuplicateButtonsCannotBecomeAUniqueTarget() async throws {
        let fixture = Fixture(duplicate: true)
        defer { fixture.close() }
        let outcome = try await NativeAXPeer.withSession { session in
            let result = try await fixture.ready(using: session)
            #expect(result.complete)
            #expect(Query.buttons(result, title: "Undo", inside: fixture.request.windowFrame).count == 2)
        }
        #expect(outcome.1.clean)
    }

    @Test func actualTraversalBudgetCannotQualifyAPartialTree() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let outcome = try await NativeAXPeer.withSession { session in
            let complete = try await fixture.ready(using: session)
            #expect(complete.complete)
            let bounded = await Query.read(fixture.request, using: session, nodeLimit: 1)
            #expect(!bounded.complete)
            #expect(bounded.failure == "AX-node-budget")
            #expect(bounded.nodes.count == 1)
            #expect(Query.buttons(bounded, title: "Undo", inside: fixture.request.windowFrame).isEmpty)
        }
        #expect(outcome.1.clean)
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

    @Test func actualLegacyScrollersKeepTheEnabledUndoDiscoverable() async throws {
        let fixture = Fixture(scroll: true)
        defer { fixture.close() }
        let outcome = try await NativeAXPeer.withSession { session in
            let value = try await fixture.ready(using: session)
            try #require(value.complete)
            #expect(value.nodes.contains { $0.role == kAXScrollBarRole })
            #expect(value.nodes.contains {
                $0.role == kAXButtonRole && $0.frame?.known == true
                    && ($0.frame?.width == 0 || $0.frame?.height == 0) && $0.enabled == nil
            })
            #expect(Query.buttons(value, title: "Undo", inside: fixture.request.contentFrame).count == 1)
        }
        #expect(outcome.1.clean)
    }

    private func absentEnabledNode(_ frame: Query.Frame?, status: AXError = .noValue,
                                   failure: String? = nil, pid: pid_t? = nil) -> Query.Node {
        let base = node(enabled: nil, pid: pid, failure: failure)
        var statuses = base.statuses
        statuses[kAXEnabledAttribute] = status.rawValue
        return Query.Node(parent: 0, pid: base.pid, role: base.role, title: base.title, label: base.label,
            enabled: nil, frame: frame, statuses: statuses, childTypes: [])
    }

    @Test func zeroAreaButtonsWithAbsentEnabledNeverBecomeTargetsOrHideDuplicates() {
        for status in [AXError.noValue, .attributeUnsupported] {
            for size in [CGSize(width: 0, height: 28), CGSize(width: 50, height: 0), .zero] {
                let empty = absentEnabledNode(.init(CGRect(origin: CGPoint(x: 20, y: 20), size: size)), status: status)
                #expect(Query.buttons(snapshot([empty]), title: "Undo", inside: probe).isEmpty)
                #expect(Query.buttons(snapshot([node(), empty]), title: "Undo", inside: probe).count == 1)
                #expect(Query.buttons(snapshot([node(), empty, node()]), title: "Undo", inside: probe).count == 2)
            }
        }
    }

    @Test func absentEnabledRequiresProvenZeroAreaAndReadableIdentity() {
        let zero = Query.Frame(CGRect(x: 20, y: 20, width: 50, height: 0))
        for invalid in [nil, frame, Query.Frame(CGRect(x: Double.nan, y: 20, width: 50, height: 0))] {
            #expect(Query.buttons(snapshot([node(), absentEnabledNode(invalid)]), title: "Undo", inside: probe).isEmpty)
        }
        for status in [AXError.success, .cannotComplete, .failure] {
            #expect(Query.buttons(snapshot([node(), absentEnabledNode(zero, status: status)]),
                title: "Undo", inside: probe).isEmpty)
        }
        for attribute in ["pid", kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                          kAXPositionAttribute, kAXSizeAttribute] {
            #expect(Query.buttons(snapshot([node(), absentEnabledNode(zero, failure: attribute)]),
                title: "Undo", inside: probe).isEmpty)
        }
        #expect(Query.buttons(snapshot([node(), absentEnabledNode(zero, pid: getpid() + 1)]),
            title: "Undo", inside: probe).isEmpty)
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

    @Test func roleLabelAndEnabledStateAreIndependentRequirements() throws {
        for candidate in [node(role: kAXGroupRole), node(label: "Redo"), node(label: nil),
                          node(enabled: false), node(enabled: nil)] {
            #expect(Query.buttons(snapshot([candidate]), title: "Undo", inside: probe).isEmpty)
        }
        #expect(Query.buttons(snapshot([node()]), title: "", inside: probe).isEmpty)
        var absent = AXError.attributeUnsupported
        let unsupported = try #require(AXValueCreate(.axError, &absent))
        let optional = Query.decodeAttributes([NSNull(), unsupported], attributes: [kAXTitleAttribute, kAXChildrenAttribute])
        #expect(optional.failure == nil && optional.values.isEmpty)
        #expect(optional.statuses[kAXTitleAttribute] == AXError.noValue.rawValue)
        #expect(optional.statuses[kAXChildrenAttribute] == AXError.attributeUnsupported.rawValue)
        var denied = AXError.cannotComplete
        let failed = try #require(AXValueCreate(.axError, &denied))
        let rejected = Query.decodeAttributes(["Undo" as NSString, failed], attributes: [kAXTitleAttribute, kAXEnabledAttribute])
        #expect(rejected.failure != nil && rejected.values.isEmpty)
        #expect(rejected.statuses[kAXEnabledAttribute] == AXError.cannotComplete.rawValue)
        var success = AXError.success
        let invalid = try #require(AXValueCreate(.axError, &success))
        #expect(Query.decodeAttributes([invalid], attributes: [kAXTitleAttribute]).failure != nil)
        #expect(Query.decodeAttributes(["Undo" as NSString], attributes: [kAXTitleAttribute, kAXEnabledAttribute]).failure != nil)
        #expect(Query.decodeAttributes(["Undo" as NSString, "Redo" as NSString],
            attributes: [kAXTitleAttribute, kAXTitleAttribute]).failure != nil)
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
        let outcome = try await NativeAXPeer.withSession { session in
            let warm = await Query.read(fixture.request, using: session)
            try #require(warm.complete)
            try #require(Query.buttons(warm, title: "Undo", inside: fixture.request.windowFrame).count == 1)
            fixture.arm()
            let request = fixture.request, entered = fixture.leaf.entered
            let query = Task.detached { await Query.read(request, using: session) }
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
        #expect(outcome.1.clean)
    }

    @Test func theLastChildMessageUsesItsOwnRemainingTimeout() async throws {
        let fixture = SlowFixture()
        defer { fixture.close() }
        let outcome = try await NativeAXPeer.withSession { session in
            let warm = await Query.read(fixture.request, using: session)
            try #require(warm.complete)
            try #require(Query.buttons(warm, title: "Undo", inside: fixture.request.windowFrame).count == 1)
            fixture.arm()
            let result = await Query.read(fixture.request, using: session, seconds: 0.2)
            #expect(result.windowCandidates == 1)
            #expect(fixture.leaf.enteredAt >= result.started)
            #expect(fixture.leaf.returnedAt > fixture.leaf.enteredAt)
            #expect(!result.complete)
            #expect(result.finished < fixture.leaf.returnedAt)
            let last = try #require(result.nodes.last)
            #expect(last.statuses[kAXChildrenAttribute] != AXError.success.rawValue)
            #expect(last.statuses["timeout:AXAttributes"] == AXError.success.rawValue)
            #expect(Query.buttons(result, title: "Undo", inside: fixture.request.contentFrame).isEmpty)
        }
        #expect(outcome.1.clean)
    }

    @Test func malformedOrAmbiguousWindowAttributeListsAreRejected() {
        let valid = [kAXRoleAttribute, kAXChildrenAttribute]
        #expect(Query.validatedWindowAttributes(valid) == valid)
        let invalid: [Any] = [[String](), [kAXRoleAttribute, kAXRoleAttribute], [""], [1],
            [String(repeating: "x", count: 257)], (0...256).map { "AX\($0)" }, ["AXRole": true]]
        for value in invalid { #expect(Query.validatedWindowAttributes(value) == nil) }
    }

    @Test func chromeSupportNeverInventsAnUnadvertisedSlot() {
        #expect(Query.supportedChromeAttributes([kAXChildrenAttribute, kAXCloseButtonAttribute]) == [kAXCloseButtonAttribute])
        #expect(Query.supportedChromeAttributes([kAXGrowAreaAttribute]) == [kAXGrowAreaAttribute])
        #expect(Query.supportedChromeAttributes([kAXChildrenAttribute]).isEmpty)
    }

    @Test func failedWindowAttributeAuthorityCannotQualifyContent() {
        let original = snapshot([node()])
        #expect(Query.buttons(original, title: "Undo", inside: probe).count == 1)
        for key in ["AXAttributeNames", "timeout:AXAttributeNames"] {
            var value = original
            value.windowAttributeStatuses[key] = AXError.failure.rawValue
            #expect(Query.buttons(value, title: "Undo", inside: probe).isEmpty)
        }
        var advertised = original
        advertised.windowAttributes.append(kAXGrowAreaAttribute)
        advertised.windowAttributeStatuses[kAXGrowAreaAttribute] = AXError.failure.rawValue
        advertised.windowAttributeStatuses["timeout:" + kAXGrowAreaAttribute] = 0
        #expect(Query.buttons(advertised, title: "Undo", inside: probe).isEmpty)
        advertised.windowAttributeStatuses[kAXGrowAreaAttribute] = nil
        advertised.windowAttributeStatuses["timeout:" + kAXGrowAreaAttribute] = nil
        #expect(Query.buttons(advertised, title: "Undo", inside: probe).count == 1)
        var unbound = advertised
        unbound.rootRivals.append(Query.Node(parent: nil, pid: getpid(), role: kAXGrowAreaRole,
            title: nil, label: nil, enabled: nil, frame: probe,
            statuses: ["pid": 0, kAXRoleAttribute: 0, kAXPositionAttribute: 0, kAXSizeAttribute: 0], childTypes: []))
        unbound.reportedRootCount += 1
        #expect(Query.buttons(unbound, title: "Undo", inside: probe).isEmpty)
        advertised.windowAttributeStatuses["timeout:" + kAXGrowAreaAttribute] = 0
        advertised.windowAttributeStatuses[kAXGrowAreaAttribute] = 0
        #expect(Query.buttons(advertised, title: "Undo", inside: probe).isEmpty)
    }

    @Test func actualWindowAttributeInventoryIsBoundToTheCompleteContent() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let outcome = try await NativeAXPeer.withSession { session in
            let result = try await fixture.ready(using: session)
            try #require(result.complete)
            #expect(Query.validatedWindowAttributes(result.windowAttributes) != nil)
            #expect(result.windowAttributeStatuses["AXAttributeNames"] == 0)
            #expect(result.windowAttributeStatuses["timeout:AXAttributeNames"] == 0)
            #expect(Set(result.chromeExclusions.keys).isSubset(of: Set(result.windowAttributes)))
            #expect(Query.buttons(result, title: "Undo", inside: fixture.request.windowFrame).count == 1)
        }
        #expect(outcome.1.clean)
    }
}
