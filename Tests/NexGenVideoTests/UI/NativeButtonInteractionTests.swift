import AppKit
import ApplicationServices
import Darwin
import SwiftUI
import Testing
@testable import NexGenVideo
import NexGenEngine
@Suite("Native SwiftUI button discovery", .serialized)
@MainActor
struct NativeButtonInteractionTests {
    private typealias Query = NativeButtonAccessibility

    @MainActor private final class Fixture {
        let window: NSWindow

        init(disabled: Bool = false, duplicate: Bool = false, split: Bool = false, rows: Int = 0,
             scroll: Bool = false, fullSizeContent: Bool = false) {
            let style: NSWindow.StyleMask = fullSizeContent
                ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                : [.titled, .closable]
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 200),
                styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            if fullSizeContent {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
            }
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
                $0.role == kAXValueIndicatorRole && $0.frame?.valid == true
                    && $0.statuses[kAXChildrenAttribute] == AXError.noValue.rawValue
            })
            #expect(value.nodes.contains {
                $0.role == kAXButtonRole && $0.frame?.valid == true
                    && $0.title == nil && $0.label == nil && $0.enabled == nil
            })
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
        let fixture = Fixture(fullSizeContent: true)
        #expect(fixture.request.contentFrame == fixture.request.windowFrame)
        #expect(Query.chromeExclusion(for: [kAXZoomButtonAttribute, kAXFullScreenButtonAttribute]) == kAXZoomButtonAttribute)
        #expect(Query.chromeExclusion(for: [kAXFullScreenButtonAttribute]) == kAXFullScreenButtonAttribute)
        #expect(Query.chromeExclusion(for: [kAXCloseButtonAttribute, kAXZoomButtonAttribute]) == nil)
        #expect(Query.chromeExclusion(for: []) == nil)
        let aliases = [kAXZoomButtonAttribute, kAXFullScreenButtonAttribute]
        let chromeFrame = Query.Frame(CGRect(x: 100, y: 20, width: 14, height: 14))
        var chrome = Query.Node(parent: nil, pid: getpid(), role: kAXButtonRole,
            title: nil, label: nil, enabled: nil, frame: chromeFrame,
            statuses: ["pid": 0, kAXRoleAttribute: 0, kAXPositionAttribute: 0, kAXSizeAttribute: 0,
                kAXZoomButtonAttribute: 0, kAXFullScreenButtonAttribute: 0], childTypes: [])
        chrome.scopeExclusion = kAXZoomButtonAttribute
        chrome.chromeMatches = aliases
        var paired = snapshot([node()])
        paired.windowAttributes.append(contentsOf: aliases)
        paired.rootRivals.append(chrome)
        paired.reportedRootCount += 1
        for alias in aliases {
            paired.chromeExclusions[alias] = chrome
            paired.windowAttributeStatuses[alias] = 0
            paired.windowAttributeStatuses["timeout:" + alias] = 0
        }
        #expect(Query.buttons(paired, title: "Undo", inside: probe).count == 1)
        var incompletePair = paired
        incompletePair.chromeExclusions[kAXFullScreenButtonAttribute] = nil
        incompletePair.windowAttributeStatuses[kAXFullScreenButtonAttribute] = nil
        incompletePair.windowAttributeStatuses["timeout:" + kAXFullScreenButtonAttribute] = nil
        #expect(Query.buttons(incompletePair, title: "Undo", inside: probe).isEmpty)
        var differentPair = paired
        differentPair.chromeExclusions[kAXFullScreenButtonAttribute] = Query.Node(parent: nil, pid: getpid(),
            role: kAXButtonRole, title: nil, label: nil, enabled: nil,
            frame: .init(chromeFrame.rect.offsetBy(dx: 20, dy: 0)), statuses: chrome.statuses, childTypes: [])
        #expect(Query.buttons(differentPair, title: "Undo", inside: probe).isEmpty)
        defer { fixture.close() }
        let outcome = try await NativeAXPeer.withSession { session in
            let result = try await fixture.ready(using: session)
            try #require(result.complete)
            #expect(Query.validatedWindowAttributes(result.windowAttributes) != nil)
            #expect(result.windowAttributeStatuses["AXAttributeNames"] == 0)
            #expect(result.windowAttributeStatuses["timeout:AXAttributeNames"] == 0)
            #expect(Set(result.chromeExclusions.keys).isSubset(of: Set(result.windowAttributes)))
            let green = try #require(result.rootRivals.first {
                $0.scopeExclusion == kAXZoomButtonAttribute || $0.scopeExclusion == kAXFullScreenButtonAttribute
            })
            #expect(green.frame?.rect.intersects(fixture.request.contentFrame.rect) == true)
            let matches = try #require(green.chromeMatches)
            let declaredSlot = try #require(matches.last)
            #expect(Query.chromeExclusion(for: matches) == green.scopeExclusion)
            try #require(result.chromeExclusions[declaredSlot] != nil)
            #expect(Query.buttons(result, title: "Undo", inside: fixture.request.windowFrame).count == 1)
            var unbound = result
            let index = try #require(unbound.rootRivals.firstIndex(of: green))
            unbound.rootRivals[index].chromeMatches = nil
            #expect(Query.buttons(unbound, title: "Undo", inside: fixture.request.windowFrame).isEmpty)
            var missingDeclaration = result
            missingDeclaration.chromeExclusions[declaredSlot] = nil
            missingDeclaration.windowAttributeStatuses[declaredSlot] = nil
            missingDeclaration.windowAttributeStatuses["timeout:" + declaredSlot] = nil
            #expect(Query.buttons(missingDeclaration, title: "Undo", inside: fixture.request.windowFrame).isEmpty)
        }
        #expect(outcome.1.clean)
    }

    @Test func unnamedButtonsRequireKnownNamesAndCannotHideNamedTargets() {
        func unnamed(title: String? = nil, label: String? = nil,
                     overrides: [String: Int32] = [:], pid: pid_t? = nil,
                     frame: Query.Frame? = nil) -> Query.Node {
            var statuses: [String: Int32] = ["pid": 0, kAXRoleAttribute: 0,
                kAXPositionAttribute: 0, kAXSizeAttribute: 0,
                kAXEnabledAttribute: AXError.attributeUnsupported.rawValue,
                kAXTitleAttribute: title == nil ? AXError.noValue.rawValue : 0,
                kAXDescriptionAttribute: label == nil ? AXError.attributeUnsupported.rawValue : 0]
            statuses.merge(overrides) { _, replacement in replacement }
            return Query.Node(parent: 0, pid: pid ?? getpid(), role: kAXButtonRole,
                title: title, label: label, enabled: nil, frame: frame ?? self.frame,
                statuses: statuses, childTypes: [])
        }
        for name in [nil, ""] as [String?] {
            let empty = unnamed(title: name, label: name)
            #expect(Query.buttons(snapshot([empty]), title: "Undo", inside: probe).isEmpty)
            #expect(Query.buttons(snapshot([empty]), title: "", inside: probe).isEmpty)
            #expect(Query.buttons(snapshot([node(), empty]), title: "Undo", inside: probe).count == 1)
            #expect(Query.buttons(snapshot([node(), empty, node()]), title: "Undo", inside: probe).count == 2)
        }
        for attribute in ["pid", kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                          kAXTitleAttribute, kAXDescriptionAttribute, kAXEnabledAttribute] {
            #expect(Query.buttons(snapshot([node(), unnamed(overrides: [attribute: AXError.cannotComplete.rawValue])]),
                title: "Undo", inside: probe).isEmpty)
        }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXEnabledAttribute] {
            #expect(Query.buttons(snapshot([node(), unnamed(overrides: [attribute: AXError.success.rawValue])]),
                title: "Undo", inside: probe).isEmpty)
        }
        for named in [unnamed(title: "Undo"), unnamed(label: "Undo"),
                      unnamed(title: "Undo", overrides: [kAXTitleAttribute: AXError.noValue.rawValue]),
                      unnamed(label: "Undo", overrides: [kAXDescriptionAttribute: AXError.attributeUnsupported.rawValue])] {
            #expect(Query.buttons(snapshot([node(), named]), title: "Undo", inside: probe).isEmpty)
        }
        #expect(Query.buttons(snapshot([node(), unnamed(pid: getpid() + 1)]), title: "Undo", inside: probe).isEmpty)
        #expect(Query.buttons(snapshot([node(), unnamed(frame: .init(CGRect(x: Double.nan, y: 20, width: 50, height: 28)))]),
            title: "Undo", inside: probe).isEmpty)
    }
}

@Suite("Native system pointer delivery", .serialized)
@MainActor
struct NativePointerInteractionTests {
    @MainActor private final class Capture {
        var callbacks: [[String: Any]] = []

        func clicked(_ name: String) {
            let point = NSEvent.mouseLocation
            callbacks.append(["name": name, "point": [point.x, point.y],
                "eventType": NSApp.currentEvent?.type.rawValue as Any? ?? NSNull(),
                "tag": NSApp.currentEvent?.cgEvent?.getIntegerValueField(.eventSourceUserData) as Any? ?? NSNull(),
                "buttonDown": CGEventSource.buttonState(.combinedSessionState, button: .left)])
        }

        func count(_ name: String) -> Int { callbacks.filter { $0["name"] as? String == name }.count }
    }

    @MainActor private struct Controls: View {
        let capture: Capture
        @State private var text = "0"

        private func button(_ title: String, disabled: Bool = false, selected: Bool = true) -> some View {
            Button(title) { capture.clicked(title) }
                .disabled(disabled)
                .background {
                    AppRelaunchClickProbe(identifier: "pointer." + title, acceptanceState: selected)
                        .allowsHitTesting(false)
                }
        }

        var body: some View {
            VStack(spacing: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("Pale room")
                        .background {
                            AppRelaunchClickProbe(identifier: "pointer.Away", acceptanceState: true)
                                .allowsHitTesting(false)
                        }
                    Spacer()
                    button("Undo")
                    button("Redo")
                }
                ScrollView {
                    NativePointerViewportStack {
                        TextField("Position", text: $text)
                            .background {
                                AppRelaunchClickProbe(identifier: "pointer.field", acceptanceState: true, acceptanceText: text)
                                    .allowsHitTesting(false)
                            }
                        HStack {
                            button("Unselected", selected: false)
                            button("Disabled", disabled: true)
                        }
                        VStack {
                            Text("Identity card")
                            Text("Character ID")
                                .background {
                                    AppRelaunchClickProbe(identifier: "pointer.Card", acceptanceState: true)
                                        .allowsHitTesting(false)
                                }
                        }
                        .padding(AppTheme.Spacing.sm)
                        .contentShape(Rectangle())
                        .onTapGesture { capture.clicked("Card") }
                        GeometryReader { _ in
                            Capsule().fill(AppTheme.Background.prominentColor)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onEnded { _ in capture.clicked("Scrubber") })
                        }
                        .frame(height: AppTheme.Control.regularHeight)
                        .background {
                            AppRelaunchClickProbe(identifier: "pointer.Scrubber", acceptanceState: true)
                                .allowsHitTesting(false)
                        }
                        NativeControl(capture: capture, popup: false)
                            .frame(height: AppTheme.Control.regularHeight)
                            .background {
                                AppRelaunchClickProbe(identifier: "pointer.Native", acceptanceState: true)
                                    .allowsHitTesting(false)
                            }
                        NativeControl(capture: capture, popup: true)
                            .frame(height: AppTheme.Control.regularHeight)
                            .background {
                                AppRelaunchClickProbe(identifier: "pointer.Choice", acceptanceState: true)
                                    .allowsHitTesting(false)
                            }
                        ForEach(0..<40, id: \.self) { index in Text("Scene property \(index)") }
                        button("Later")
                    }
                }
                DisabledSibling()
            }
            .buttonStyle(.capsule())
            .padding(AppTheme.Spacing.md)
        }
    }

    @MainActor private struct NativeControl: NSViewRepresentable {
        let capture: Capture
        let popup: Bool

        @MainActor final class Coordinator: NSObject {
            let capture: Capture
            init(_ capture: Capture) { self.capture = capture }
            @objc func selected(_ sender: NSControl) {
                capture.clicked((sender as? NSPopUpButton)?.titleOfSelectedItem ?? "Native")
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator(capture) }
        func makeNSView(context: Context) -> NSControl {
            let view: NSControl
            if popup {
                let button = NSPopUpButton(frame: .zero, pullsDown: false)
                button.addItems(withTitles: ["First", "Second"])
                view = button
            } else { view = NSButton(title: "Native", target: nil, action: nil) }
            view.target = context.coordinator
            view.action = #selector(Coordinator.selected(_:))
            return view
        }

        func updateNSView(_ view: NSControl, context: Context) {}
    }

    @MainActor private final class Hosting: NSHostingView<Controls> {
        var substitutedHit: Any?
        override func accessibilityHitTest(_ point: NSPoint) -> Any? {
            substitutedHit ?? super.accessibilityHitTest(point)
        }
    }

    @MainActor private final class ReplacementHit: NSAccessibilityElement {
        let window: NSWindow
        let frame: NSRect
        let role: NSAccessibility.Role
        init(window: NSWindow, frame: NSRect, role: NSAccessibility.Role = .button) {
            self.window = window; self.frame = frame; self.role = role; super.init()
        }
        override func accessibilityRole() -> NSAccessibility.Role? { role }
        override func accessibilityFrame() -> NSRect { frame }
        override func accessibilityParent() -> Any? { window }
        override func isAccessibilityEnabled() -> Bool { true }
    }

    private struct DisabledSibling: NSViewRepresentable {
        func makeNSView(context: Context) -> NSButton {
            let button = NSButton(title: "Unrelated disabled control", target: nil, action: nil)
            button.isEnabled = false
            return button
        }

        func updateNSView(_ view: NSButton, context: Context) {}
    }

    @MainActor private final class Fixture {
        let capture: Capture
        let window: NSWindow
        let output: URL
        let driver: ProductionVisualSourcesDriver
        private let application: NativePointerApplicationLease
        let context: NativePointerFixtureContext
        init(_ name: String) async throws {
            try #require(ProcessInfo.processInfo.arguments.contains("--no-parallel"))
            let events = try #require(ProcessInfo.processInfo.environment["NGV_APPKIT_TEST_EVENTS"])
            let folder = URL(fileURLWithPath: events).deletingLastPathComponent()
                .appendingPathComponent("native-pointer-" + name + "-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let acquiredApplication = try await NativePointerApplicationLease.acquire(); application = acquiredApplication; let created = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 390, height: 640),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
            let captured = Capture()
            capture = captured
            window = created
            output = folder

            driver = ProductionVisualSourcesDriver(window: created, output: folder, name: name); context = try NativePointerFixtureContext.owned(window: created, application: acquiredApplication, output: folder)
            window.isReleasedWhenClosed = false
            window.contentView = Hosting(rootView: Controls(capture: capture))

            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func ready(unobscured: [String] = []) async throws {
            var viewport = NativePointerViewportReadiness()
            let began = ProcessInfo.processInfo.systemUptime
            let targets = unobscured.map { "foreground:" + $0 }
            let clauses = ["active", "key", "presentation", "probe", "viewport"] + targets + ["settled-viewport"]
            do {
                try await context.wait("exclusive native pointer fixture", driver: driver, clauses: clauses) {
                    let ready = self.context.operand("active", NSApp.isActive) && self.context.operand("key", self.window.isKeyWindow) && self.context.operand("presentation", nativePointerWindowPresented(self.window)) && self.context.operand("probe", self.probe("Undo") != nil) && self.context.operand("viewport", nativePointerViewportReady(in: self.window))
                    guard ready, unobscured.allSatisfy({ self.context.operand("foreground:" + $0, self.isForeground($0)) })
                    else { viewport.reset(); return false }
                    return self.context.operand("settled-viewport", viewport.observe(NativePointerViewportReadiness.Sample.current(in: self.window), at: ProcessInfo.processInfo.systemUptime))
                }
            } catch {
                viewportReadiness = viewport.evidence.merging(["waitSeconds": ProcessInfo.processInfo.systemUptime - began, "ready": false]) { _, new in new }
                do { try record("viewport-readiness", viewportReadiness) }
                catch { FileHandle.standardError.write(Data(("VIEWPORT_READINESS_EVIDENCE_FAIL " + error.localizedDescription + "\n").utf8)) }
                throw error
            }
            viewportReadiness = viewport.evidence.merging(["waitSeconds": ProcessInfo.processInfo.systemUptime - began, "ready": true]) { _, new in new }
            try record("viewport-readiness", viewportReadiness)
            try await context.fill("pointer.field", value: "0.5", driver: driver)
            try #require(window.firstResponder is NSTextView)
        }

        func probe(_ title: String) -> NSView? {
            window.contentView.flatMap { WorkspaceUIAcceptance.findProbe(in: $0, identifier: "pointer." + title) }
        }

        private func isForeground(_ title: String) -> Bool {
            guard let view = probe(title), view.window === window,
                  !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return false }
            return NSWindow.windowNumber(at: screenCenter(of: view), belowWindowWithWindowNumber: 0) == window.windowNumber
        }

        private func screenCenter(of view: NSView) -> NSPoint {
            let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            return window.convertPoint(toScreen: view.convert(center, to: nil))
        }

        func point(_ title: String) throws -> NSPoint {
            screenCenter(of: try #require(probe(title)))
        }

        func moveAway() async throws {
            let screen = try #require(NSScreen.screens.first)
            let away = try #require(probe("Away"))
            try #require(away.window === window && !away.isHiddenOrHasHiddenAncestor && !away.visibleRect.isEmpty)
            let point = try self.point("Away")
            try await ProductionNativeReadingAcceptance.movePointer(to: CGPoint(x: point.x, y: screen.frame.maxY - point.y),
                                                                    window: window, driver: driver)
        }

        func input(_ title: String) throws -> [String: Any] {
            let pointer = try #require(driver.interactions.last { $0["id"] as? String == "pointer." + title && $0["kind"] as? String == "pointer" })
            return try #require(pointer["nativeInput"] as? [String: Any])
        }

        func record(_ name: String, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                .write(to: output.appendingPathComponent(name + ".json"), options: .atomic)
        }

        func close() {
            context.close(); window.contentView = nil
            window.close()
            application.close(); context.applicationRestored()
        }

        private(set) var viewportReadiness: [String: Any] = [:]
    }

    private func delivered(_ title: String, in fixture: Fixture, movements: Int = 1) throws {
        let input = try fixture.input(title)
        let posted = try #require(input["posted"] as? [[String: Any]])
        let received = try #require(input["received"] as? [[String: Any]])
        #expect(input["status"] as? String == "delivered")
        #expect(posted.filter { $0["type"] as? UInt32 == CGEventType.mouseMoved.rawValue }.count == movements)
        #expect(posted.filter { $0["type"] as? UInt32 == CGEventType.leftMouseDown.rawValue }.count == 1)
        #expect(posted.filter { $0["type"] as? UInt32 == CGEventType.leftMouseUp.rawValue }.count == 1)
        #expect(received.filter { $0["type"] as? UInt == NSEvent.EventType.mouseMoved.rawValue }.count == movements)
        #expect(received.filter { $0["type"] as? UInt == NSEvent.EventType.leftMouseDown.rawValue }.count == 1)
        let localUps = received.filter { $0["type"] as? UInt == NSEvent.EventType.leftMouseUp.rawValue }.count
        #expect(localUps <= 1)
        #expect(input["localMonitorDownObserved"] as? Bool == true)
        #expect(input["localMonitorUpObserved"] as? Bool == (localUps == 1))
        #expect(input["buttonDownObserved"] as? Bool == true)
        #expect(input["buttonReleased"] as? Bool == true)
        let expected = try fixture.point(title)
        let callback = try #require(fixture.capture.callbacks.last { $0["name"] as? String == title })
        let point = try #require(callback["point"] as? [CGFloat])
        #expect(abs(point[0] - expected.x) < 0.5 && abs(point[1] - expected.y) < 0.5)
        #expect(callback["tag"] as? Int64 == input["tag"] as? Int64)
    }

    @Test func actualCompactButtonsUseOneTaggedSystemClickEach() async throws {
        let legacy = try await Fixture("legacy-observation")
        do {
            try await legacy.ready()
            try await legacy.moveAway()
            let before = NSEvent.mouseLocation
            try #require(WorkspaceUIAcceptance.click(identifier: "pointer.Undo", in: legacy.window) == nil)
            try await Task.sleep(for: .milliseconds(100))
            let after = NSEvent.mouseLocation
            try legacy.record("legacy-observation", ["before": [before.x, before.y], "after": [after.x, after.y],
                "target": [try legacy.point("Undo").x, try legacy.point("Undo").y], "callbacks": legacy.capture.callbacks,
                "observationOnly": true])
        } catch { legacy.close(); throw error }
        legacy.close()
        let fixture = try await Fixture("adjacent-buttons")
        defer { fixture.close() }
        let screen = try #require(fixture.window.screen)
        fixture.window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: fixture.window.frame.minY))
        try await fixture.ready(unobscured: ["Away", "field", "Undo", "Redo"])
        try await fixture.moveAway()
        try await fixture.driver.click("pointer.Undo", in: fixture.window)
        try await fixture.driver.wait("Undo callback") { fixture.capture.count("Undo") == 1 }
        try delivered("Undo", in: fixture)
        try await fixture.driver.click("pointer.Redo", in: fixture.window)
        try await fixture.driver.wait("Redo callback") { fixture.capture.count("Redo") == 1 }
        try delivered("Redo", in: fixture)
        #expect(fixture.capture.count("Undo") == 1)
        try await fixture.driver.click("pointer.Redo", in: fixture.window)
        try await fixture.driver.wait("second deliberate Redo callback") { fixture.capture.count("Redo") == 2 }
        try delivered("Redo", in: fixture, movements: 2)
        #expect(fixture.capture.count("Undo") == 1)
        try fixture.driver.capture("native-adjacent-buttons", target: fixture.window)
        try fixture.record("callbacks", ["callbacks": fixture.capture.callbacks])
    }

    @Test func unselectedAndDisabledTargetsKeepDifferentMeaning() async throws {
        let fixture = try await Fixture("selection-disabled")
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.driver.click("pointer.Unselected", in: fixture.window, enabled: false)
        try await fixture.driver.wait("unselected enabled callback") { fixture.capture.count("Unselected") == 1 }
        try delivered("Unselected", in: fixture)
        let counter = DownCounter()
        defer { counter.close() }
        do {
            try await fixture.driver.click("pointer.Disabled", in: fixture.window, enabled: false)
            Issue.record("A disabled SwiftUI control accepted a native Down.")
        } catch {
            #expect(!CGEventSource.buttonState(.combinedSessionState, button: .left))
        }
        #expect(fixture.capture.count("Disabled") == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 0)
        let input = try fixture.input("Disabled")
        #expect((input["posted"] as? [Any])?.isEmpty == true)
        #expect(input["ownedDownPosted"] as? Bool == false)
    }

    @Test func mouseIgnoringWindowAllowsOneClickAndInputCatchingWindowRefusesIt() async throws {
        let fixture = try await Fixture("window-input-hit")
        defer { fixture.close() }
        try await fixture.ready()
        let overlay = NSWindow(contentRect: fixture.window.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.backgroundColor = .windowBackgroundColor
        overlay.ignoresMouseEvents = true
        overlay.order(.above, relativeTo: fixture.window.windowNumber)
        defer { overlay.close() }
        try await fixture.driver.wait("mouse-ignoring overlay presentation") { nativePointerOverlayPresented(overlay, above: fixture.window, at: try? fixture.point("Undo"), receiver: fixture.window) }
        let windows = try #require(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])
        let overlayIndex = try #require(windows.firstIndex { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == overlay.windowNumber })
        let originalIndex = try #require(windows.firstIndex { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == fixture.window.windowNumber })
        try #require(overlayIndex < originalIndex)
        let row = windows[overlayIndex]
        try #require((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0)
        let bounds = try #require(row[kCGWindowBounds as String] as? [String: Any])
        let rect = try #require(CGRect(dictionaryRepresentation: bounds as CFDictionary))
        let screen = try #require(NSScreen.screens.first)
        let point = try fixture.point("Undo")
        try #require(rect.contains(CGPoint(x: point.x, y: screen.frame.maxY - point.y)))
        try await fixture.moveAway()
        try await fixture.driver.click("pointer.Undo", in: fixture.window)
        try await fixture.driver.wait("click through mouse-ignoring window") { fixture.capture.count("Undo") == 1 }
        try delivered("Undo", in: fixture)
        let counter = DownCounter()
        defer { counter.close() }
        overlay.ignoresMouseEvents = false; overlay.order(.above, relativeTo: fixture.window.windowNumber)
        try await fixture.driver.wait("input-catching overlay presentation") { nativePointerOverlayPresented(overlay, above: fixture.window, at: point, receiver: overlay) }
        try #require(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == overlay.windowNumber)
        do {
            try await fixture.driver.click("pointer.Undo", in: fixture.window)
            Issue.record("An input-catching window accepted a click through to the original window.")
        } catch { try verifyPermanentCoverRefusal(error, cover: overlay, driver: fixture.driver) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 0)
        #expect(fixture.capture.count("Undo") == 1)
        #expect((try fixture.input("Undo")["posted"] as? [Any])?.isEmpty == true)
        #expect(!CGEventSource.buttonState(.combinedSessionState, button: .left))
        try fixture.record("window-input-hit", ["callbacks": fixture.capture.callbacks, "refusedDownCount": counter.count])
    }

    @Test func coveredForeignAndInvalidTargetsNeverPostDown() async throws {
        let fixture = try await Fixture("refused-targets")
        defer { fixture.close() }
        try await fixture.ready()
        let counter = DownCounter()
        defer { counter.close() }
        let root = try #require(fixture.window.contentView)
        let probe = try #require(fixture.probe("Undo"))
        try nativePointerOwnedHostingAdmissionAssertions(window: fixture.window); let cover = NSView(frame: probe.convert(probe.bounds, to: root))
        root.addSubview(cover)
        do {
            try await fixture.driver.click("pointer.Undo", in: fixture.window)
            Issue.record("An unrelated native cover accepted pointer input.")
        } catch {}
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 0)
        #expect(fixture.capture.count("Undo") == 0)
        #expect((try fixture.input("Undo")["posted"] as? [Any])?.isEmpty == true)
        cover.removeFromSuperview()
        for fraction in [NSPoint(x: .nan, y: 0.5), NSPoint(x: 1.1, y: 0.5)] {
            do {
                try await fixture.driver.click("pointer.Undo", in: fixture.window, fraction: fraction)
                Issue.record("An invalid pointer fraction was accepted.")
            } catch {}
            try await Task.sleep(for: .milliseconds(100))
            #expect(counter.count == 0)
        }
        let foreign = NSWindow(contentRect: fixture.window.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        foreign.makeKeyAndOrderFront(nil)
        defer { foreign.close() }
        try await fixture.driver.wait("foreign key fixture presentation") { foreign.isKeyWindow && nativePointerWindowPresented(foreign) }; do {
            try await fixture.driver.click("pointer.Undo", in: fixture.window)
            Issue.record("A foreign key window did not prevent pointer input.")
        } catch {}
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 0)
        #expect(fixture.capture.count("Undo") == 0)
        #expect(!CGEventSource.buttonState(.combinedSessionState, button: .left))
    }

    @MainActor private final class DownCounter {
        var count = 0
        private var monitor: Any?
        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                MainActor.assumeIsolated { self.count += 1 }
                return event
            }
        }
        func close() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    @Test func gestureSurfacesAndSmallCardMarkersRemainUsable() async throws {
        let fixture = try await Fixture("gesture-surfaces")
        defer { fixture.close() }
        try await fixture.ready()
        for title in ["Card", "Scrubber"] {
            try await fixture.moveAway()
            try await fixture.driver.click("pointer." + title, in: fixture.window)
            try await fixture.driver.wait("gesture callback " + title) { fixture.capture.count(title) == 1 }
            try delivered(title, in: fixture)
        }
        try fixture.record("callbacks", ["callbacks": fixture.capture.callbacks])
    }

    @Test func actualNativeControlAndMenuTrackingKeepTheirCallbacks() async throws {
        let fixture = try await Fixture("native-tracking")
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.moveAway()
        try await fixture.driver.click("pointer.Native", in: fixture.window)
        try await fixture.driver.wait("actual NSButton callback") { fixture.capture.count("Native") == 1 }
        try delivered("Native", in: fixture)
        try await fixture.driver.menu("pointer.Choice", title: "Second", in: fixture.window)
        try await fixture.driver.wait("actual popup menu selection") { fixture.capture.count("Second") == 1 }
        let input = try fixture.input("Choice")
        #expect(input["buttonDownObserved"] as? Bool == true)
        #expect(input["buttonReleased"] as? Bool == true)
        #expect(fixture.capture.count("Native") == 1)
        try fixture.record("callbacks", ["callbacks": fixture.capture.callbacks])
    }

    @Test func changedAccessibilityHitCannotBorrowTheOriginalGeometry() async throws {
        let fixture = try await Fixture("changed-accessibility-target")
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.moveAway()
        let root = try #require(fixture.window.contentView as? Hosting)
        let probe = try #require(fixture.probe("Undo"))
        let frame = fixture.window.convertToScreen(probe.convert(probe.bounds, to: nil))
        try await fixture.driver.click("pointer.Undo", in: fixture.window)
        try await fixture.driver.wait("original accessibility target callback") { fixture.capture.count("Undo") == 1 }
        try delivered("Undo", in: fixture)
        try #require(try fixture.input("Undo")["status"] as? String == "delivered")
        try #require(fixture.capture.count("Undo") == 1)
        let replacement = ReplacementHit(window: fixture.window, frame: frame)
        let counter = DownCounter()
        defer { counter.close() }
        for role in [NSAccessibility.Role(rawValue: kAXUnknownRole), NSAccessibility.Role(rawValue: "AXUnrecognizedFixtureRole")] {
            root.substitutedHit = ReplacementHit(window: fixture.window, frame: frame, role: role)
            do {
                try await fixture.driver.click("pointer.Undo", in: fixture.window)
                Issue.record("An unknown accessibility role qualified a gesture target.")
            } catch {
                #expect((error as? GateBlocked)?.message == "The pointer accessibility ancestry has an unknown role.")
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(counter.count == 0)
            #expect(fixture.capture.count("Undo") == 1)
            #expect((try fixture.input("Undo")["posted"] as? [Any])?.isEmpty == true)
        }
        let disabled = CanonicalAXLeaf(window: fixture.window, frame: frame)
        disabled.roleValue = .button
        disabled.enabled = false
        root.substitutedHit = disabled
        do {
            try await fixture.driver.click("pointer.Undo", in: fixture.window)
            Issue.record("A disabled SwiftUI accessibility control accepted pointer input.")
        } catch {
            #expect((error as? GateBlocked)?.message == "The actual pointer control is disabled or has changed geometry.")
        }
        #expect(counter.count == 0)
        #expect(fixture.capture.count("Undo") == 1)
        #expect((try fixture.input("Undo")["posted"] as? [Any])?.isEmpty == true)
        root.substitutedHit = nil
        try await fixture.moveAway()
        let number = fixture.window.windowNumber
        let witness = CanonicalChangeWitness()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            let owned = event.windowNumber == number && (event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0) > 0
            MainActor.assumeIsolated {
                if owned {
                    witness.switched = true
                    root.substitutedHit = replacement
                }
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        do {
            try await fixture.driver.click("pointer.Undo", in: fixture.window)
            Issue.record("A different accessibility target borrowed the original hosting surface and geometry.")
        } catch {
            #expect((error as? GateBlocked)?.message == "The actual system pointer or original control changed before Down.")
        }
        #expect(witness.switched)
        #expect((root.substitutedHit as? ReplacementHit) === replacement)
        let input = try fixture.input("Undo")
        let posted = try #require(input["posted"] as? [[String: Any]])
        let received = try #require(input["received"] as? [[String: Any]])
        let preDown = try #require(input["preDownGuard"] as? [String: Any])
        #expect(preDown["firstFailedClause"] as? String == "originalTarget")
        let comparisons = try #require(preDown["targetComparisons"] as? [String: Bool])
        #expect(comparisons["accessibility"] == false)
        #expect(posted.filter { $0["type"] as? UInt32 == CGEventType.mouseMoved.rawValue }.count == 1)
        #expect(received.filter { $0["type"] as? UInt == NSEvent.EventType.mouseMoved.rawValue }.count == 1)
        #expect(!posted.contains { $0["type"] as? UInt32 == CGEventType.leftMouseDown.rawValue })
        #expect(input["ownedDownPosted"] as? Bool == false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 0)
        #expect(fixture.capture.count("Undo") == 1)
        #expect(!CGEventSource.buttonState(.combinedSessionState, button: .left))
        #expect(try #require(fixture.probe("Undo")) === probe)
        #expect(fixture.window.convertToScreen(probe.convert(probe.bounds, to: nil)) == frame)
    }

    @MainActor private final class TaskBox {
        var task: Task<Void, Error>?
        var competitor: Task<Void, Never>?
        var competitorRefused = false
        var competingMovementRefused = false
    }

    private final class DropFirstUp: @unchecked Sendable {
        private let lock = NSLock()
        private var dropped = false
        private var actualDowns = 0
        private var actualUps = 0

        func send(_ event: CGEvent) {
            lock.lock()
            if event.type == .leftMouseUp && !dropped {
                dropped = true
                lock.unlock()
                return
            }
            if event.type == .leftMouseDown { actualDowns += 1 }
            if event.type == .leftMouseUp { actualUps += 1 }
            lock.unlock()
            event.post(tap: .cghidEventTap)
        }

        var evidence: [String: Any] {
            lock.lock(); defer { lock.unlock() }
            return ["firstUpDeliberatelyDropped": dropped, "actualDownPosts": actualDowns, "actualUpPosts": actualUps]
        }
    }

    @Test func aLostUpGetsOnlyOneReleaseCleanup() async throws {
        let fixture = try await Fixture("lost-up-cleanup")
        defer { fixture.close() }
        try await fixture.ready()
        let token = try NativeAcceptancePointer.claim()
        defer { NativeAcceptancePointer.release(token) }
        let appKitPoint = try fixture.point("Undo")
        let screen = try #require(NSScreen.screens.first)
        let point = CGPoint(x: appKitPoint.x, y: screen.frame.maxY - appKitPoint.y)
        try await ProductionNativeReadingAcceptance.movePointer(to: point, window: fixture.window, driver: fixture.driver, transaction: token)
        let source = try #require(CGEventSource(stateID: .combinedSessionState))
        let down = try #require(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
        let up = try #require(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
        let tag = Int64.random(in: 1...Int64.max)
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        defer { if CGEventSource.buttonState(.combinedSessionState, button: .left) { up.post(tap: .cghidEventTap) } }
        let windows = try #require(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])
        let original = try #require(windows.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
            && ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == fixture.window.windowNumber })
        let rawBounds = try #require(original[kCGWindowBounds as String] as? [String: Any])
        let bounds = try #require(CGRect(dictionaryRepresentation: rawBounds as CFDictionary))
        let dropped = DropFirstUp()
        let poster = NativePointerPoster(source: source, down: down, up: up, point: point,
            window: fixture.window.windowNumber, windowBounds: bounds, screenPoint: appKitPoint,
            tag: tag, deliver: { dropped.send($0) })
        let number = fixture.window.windowNumber
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if event.windowNumber == number, event.cgEvent?.getIntegerValueField(.eventSourceUserData) == tag,
               CGEventSource.buttonState(.combinedSessionState, button: .left) { poster.observedDown() }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        await Task.detached { await poster.run() }.value
        let state = poster.snapshot(), actual = dropped.evidence
        #expect(state["buttonDownObserved"] as? Bool == true)
        #expect(state["cleanupUpPosted"] as? Bool == true)
        #expect(state["buttonReleased"] as? Bool == true)
        #expect(state["error"] as? String == "The original Up did not release the OS button.")
        #expect(actual["firstUpDeliberatelyDropped"] as? Bool == true)
        #expect(actual["actualDownPosts"] as? Int == 1)
        #expect(actual["actualUpPosts"] as? Int == 1)
        #expect(!CGEventSource.buttonState(.combinedSessionState, button: .left))
        #expect(fixture.capture.count("Undo") <= 1)
        try fixture.record("release-control", ["transportFaultInjected": true, "poster": state, "actualTransport": actual])
    }

    @Test func ownedDownIsReleasedWhenTheTaskIsCancelled() async throws {
        let fixture = try await Fixture("cancelled-down")
        defer { fixture.close() }
        try await fixture.ready()
        let box = TaskBox(), number = fixture.window.windowNumber
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            let owned = event.windowNumber == number && (event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0) > 0
            MainActor.assumeIsolated { if owned { box.task?.cancel() } }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        box.task = Task { try await fixture.driver.click("pointer.Undo", in: fixture.window) }
        do {
            try await box.task!.value
            Issue.record("The cancelled pointer transaction reported delivery success.")
        } catch { #expect(error is CancellationError) }
        let input = try fixture.input("Undo")
        let posted = try #require(input["posted"] as? [[String: Any]])
        #expect(posted.filter { $0["type"] as? UInt32 == CGEventType.leftMouseDown.rawValue }.count == 1)
        #expect(posted.filter { $0["type"] as? UInt32 == CGEventType.leftMouseUp.rawValue }.count == 1)
        #expect(input["ownedUpPosted"] as? Bool == true)
        #expect(input["buttonReleased"] as? Bool == true)
        #expect(fixture.capture.count("Undo") <= 1)
        #expect(!CGEventSource.buttonState(.combinedSessionState, button: .left))
        let next = try NativeAcceptancePointer.claim()
        NativeAcceptancePointer.release(next)
    }

    @Test func concurrentButtonPreparationCannotMoveTheOwnedPointer() async throws {
        let fixture = try await Fixture("concurrent-preparation")
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.moveAway()
        let box = TaskBox(), number = fixture.window.windowNumber
        let screen = try #require(NSScreen.screens.first)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            let owned = event.windowNumber == number && (event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0) > 0
            MainActor.assumeIsolated {
                guard owned, box.competitor == nil else { return }
                box.competitor = Task {
                    let before = NSEvent.mouseLocation
                    do {
                        try await fixture.driver.clickButton("pointer.Later", title: "Later", in: fixture.window)
                        Issue.record("Competing button preparation entered the owned pointer transaction.")
                    } catch {
                        #expect((error as? GateBlocked)?.message == "A native pointer transaction is already active.")
                        box.competitorRefused = (error as? GateBlocked)?.message == "A native pointer transaction is already active."
                    }
                    do {
                        try await ProductionNativeReadingAcceptance.movePointer(
                            to: CGPoint(x: before.x, y: screen.frame.maxY - before.y),
                            window: fixture.window, driver: fixture.driver)
                        Issue.record("Competing wheel preparation entered the owned pointer transaction.")
                    } catch {
                        #expect((error as? GateBlocked)?.message == "A native pointer transaction is already active.")
                        box.competingMovementRefused = (error as? GateBlocked)?.message == "A native pointer transaction is already active."
                    }
                    #expect(NSEvent.mouseLocation == before)
                }
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        try await fixture.driver.click("pointer.Undo", in: fixture.window)
        let competitor = try #require(box.competitor)
        await competitor.value
        #expect(box.competitorRefused)
        #expect(box.competingMovementRefused)
        try await fixture.driver.wait("single unperturbed callback") { fixture.capture.count("Undo") == 1 }
        #expect(fixture.capture.count("Later") == 0)
        try delivered("Undo", in: fixture)
    }

    @Test func viewportWidthPreservesFieldAndNativeWheelAcrossScrollerStyles() async throws {
        try await verifyWheelTargetingInSceneViewport()
        for style in [NSScroller.Style.legacy, .overlay] {
            let fixture = try await Fixture("viewport-" + String(style.rawValue))
            defer { fixture.close() }
            try await fixture.context.wait("native viewport fixture", driver: fixture.driver, clauses: ["active", "key", "field-probe"]) {
                fixture.context.operand("active", NSApp.isActive) && fixture.context.operand("key", fixture.window.isKeyWindow) && fixture.context.operand("field-probe", fixture.probe("field") != nil)
            }
            let viewportSize = try #require(fixture.window.contentView?.bounds.size)
            let windowReadyBegan = ProcessInfo.processInfo.systemUptime
            try await ProductionSceneUIAcceptance.waitForViewport(viewportSize, driver: fixture.driver)
            let windowReadySeconds = ProcessInfo.processInfo.systemUptime - windowReadyBegan
            #expect(windowReadySeconds >= 0.25)
            let field = try #require(fixture.probe("field"))
            let scroll = try #require(field.enclosingScrollView)
            scroll.scrollerStyle = style
            try await fixture.ready()
            #expect((fixture.viewportReadiness["waitSeconds"] as? Double ?? 0) >= 0.25)
            #expect((fixture.viewportReadiness["stableSeconds"] as? Double ?? 0) >= 0.25)
            #expect((fixture.viewportReadiness["samples"] as? Int ?? 0) >= 2)
            let observed = try #require(fixture.viewportReadiness["lastObserved"] as? [String: Any])
            #expect(observed["style"] as? Int == Int(style.rawValue))
            let sample = try #require(NativePointerViewportReadiness.Sample.current(in: fixture.window))
            #expect(sample.fieldFrame.width == sample.clipBounds.width)
            var readiness = NativePointerViewportReadiness()
            let initialObservation = readiness.observe(sample, at: 10)
            #expect(!initialObservation)
            let beforeStableBoundary = readiness.observe(sample, at: 10.249)
            #expect(!beforeStableBoundary)
            let atStableBoundary = readiness.observe(sample, at: 10.25)
            #expect(atStableBoundary)
            var changed = sample
            changed.fieldFrame.origin.y += 0.25
            #expect(changed.isValid)
            let geometryReset = readiness.observe(changed, at: 11)
            #expect(!geometryReset)
            let stableGeometry = readiness.observe(changed, at: 11.25)
            #expect(stableGeometry)
            let replacement = NSView()
            changed.objects[2] = replacement
            let identityReset = readiness.observe(changed, at: 12)
            #expect(!identityReset)
            let stableIdentity = readiness.observe(changed, at: 12.25)
            #expect(stableIdentity)
            changed.style = Int(style == .legacy ? NSScroller.Style.overlay.rawValue : NSScroller.Style.legacy.rawValue)
            let styleReset = readiness.observe(changed, at: 12.5)
            #expect(!styleReset)
            let stableStyle = readiness.observe(changed, at: 12.75)
            #expect(stableStyle)
            var stale = changed
            stale.fieldFrame.size.width -= 1
            let widthReset = readiness.observe(stale, at: 13)
            #expect(!widthReset)
            let afterWidthReset = readiness.observe(changed, at: 14)
            #expect(!afterWidthReset)
            let stableAfterWidthReset = readiness.observe(changed, at: 14.25)
            #expect(stableAfterWidthReset)
            let missingSampleReset = readiness.observe(nil, at: 15)
            #expect(!missingSampleReset)
            let afterMissingSample = readiness.observe(changed, at: 16)
            #expect(!afterMissingSample)
            let stableAfterMissingSample = readiness.observe(changed, at: 16.25)
            #expect(stableAfterMissingSample)
            let regressingClockReset = readiness.observe(changed, at: 16)
            #expect(!regressingClockReset)
            let stableAfterClockReset = readiness.observe(changed, at: 16.25)
            #expect(stableAfterClockReset)
            let invalidClockReset = readiness.observe(changed, at: .nan)
            #expect(!invalidClockReset)
            let afterInvalidClock = readiness.observe(changed, at: 17)
            #expect(!afterInvalidClock)
            let stableAfterInvalidClock = readiness.observe(changed, at: 17.25)
            #expect(stableAfterInvalidClock)
            #expect(scroll.scrollerStyle == style)
            let clip = scroll.contentView
            let fieldFrame = field.convert(field.bounds, to: clip)
            #expect(clip.bounds.contains(fieldFrame))
            let document = try #require(scroll.documentView)
            #expect(document.bounds.height > clip.bounds.height)
            let later = try #require(fixture.probe("Later"))
            let initiallyOutside = !clip.bounds.contains(later.convert(later.bounds, to: clip))
            #expect(initiallyOutside)
            let before = clip.bounds.origin
            try await fixture.moveAway()
            let interactionStart = fixture.driver.interactions.count
            try await fixture.driver.click("pointer.Later", in: fixture.window)
            try await fixture.driver.wait("Later callback after native wheel") { fixture.capture.count("Later") == 1 }
            #expect(field.enclosingScrollView === scroll && later.enclosingScrollView === scroll)
            #expect(scroll.contentView === clip && scroll.scrollerStyle == style)
            #expect(clip.bounds.contains(later.convert(later.bounds, to: clip)))
            #expect(field.convert(field.bounds, to: clip).width <= clip.bounds.width)
            #expect(clip.bounds.origin != before)
            let wheels = fixture.driver.interactions.dropFirst(interactionStart).filter {
                $0["kind"] as? String == "wheel" && $0["id"] as? String == "pointer.Later"
            }
            #expect(!wheels.isEmpty)
            #expect(wheels.allSatisfy { $0["nativeScrollEnded"] as? Bool == true })
            #expect(wheels.allSatisfy { ($0["settledGeometrySamples"] as? Int ?? 0) >= 2 })
            #expect(wheels.allSatisfy { ($0["settledGeometrySeconds"] as? Double ?? 0) >= 0.25 })
            #expect(wheels.contains { wheel in
                guard let start = wheel["before"] as? [CGFloat], let end = wheel["after"] as? [CGFloat],
                      start.count == 2, end.count == 2 else { return false }
                return (start + end).allSatisfy(\.isFinite) && start != end
            })
            #expect(fixture.capture.count("Later") == 1)
            try delivered("Later", in: fixture)
            try fixture.record("viewport", ["style": style.rawValue, "fieldFrame": NSStringFromRect(fieldFrame),
                "windowReadySeconds": windowReadySeconds,
                "fieldReadiness": fixture.viewportReadiness,
                "viewport": NSStringFromRect(clip.bounds), "before": [before.x, before.y],
                "after": [clip.bounds.origin.x, clip.bounds.origin.y], "laterInitiallyOutside": initiallyOutside,
                "wheels": Array(wheels), "callbacks": fixture.capture.callbacks])
        }
    }

    @MainActor private final class CanonicalAXLeaf: NSView {
        var roleValue: NSAccessibility.Role? = .textField
        var enabled = true
        var measuredFrame: NSRect
        var parentElement: (any AnyObject & Sendable)?

        init(window: NSWindow, frame: NSRect) {
            measuredFrame = frame
            parentElement = window
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { return nil }
        override func accessibilityRole() -> NSAccessibility.Role? { MainActor.assumeIsolated { roleValue?.rawValue }.map { NSAccessibility.Role(rawValue: $0) } }
        override func accessibilityFrame() -> NSRect { MainActor.assumeIsolated { measuredFrame } }
        override func accessibilityParent() -> Any? { MainActor.assumeIsolated { () -> (any AnyObject & Sendable)? in parentElement } }
        override func isAccessibilityEnabled() -> Bool { MainActor.assumeIsolated { enabled } }
    }

    @MainActor private final class CanonicalNativeControl: NSControl {
        var canonicalHit: (any Sendable)?
        var downTags: [Int64] = []
        var downWasPressed = false
        var upCount = 0

        override func accessibilityRole() -> NSAccessibility.Role? { .init(rawValue: kAXUnknownRole) }
        override func accessibilityHitTest(_ point: NSPoint) -> Any? { MainActor.assumeIsolated { () -> (any Sendable)? in canonicalHit } }
        override func isAccessibilityEnabled() -> Bool { isEnabled }
        override func mouseDown(with event: NSEvent) {
            downTags.append(event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
            downWasPressed = CGEventSource.buttonState(.combinedSessionState, button: .left)
        }
        override func mouseUp(with event: NSEvent) { upCount += 1 }
    }

    @MainActor private final class CanonicalChangeWitness {
        var switched = false
    }

    @MainActor private final class MethodBasedAXElement {
        var role: NSAccessibility.Role
        var frame: NSRect
        var parent: AnyObject
        var enabled = true

        init(role: NSAccessibility.Role, frame: NSRect, parent: AnyObject) {
            self.role = role
            self.frame = frame
            self.parent = parent
        }

        @objc func accessibilityRole() -> NSAccessibility.Role? { role }
        @objc func accessibilityFrame() -> NSRect { frame }
        @objc func accessibilityParent() -> Any? { parent }
        @objc func isAccessibilityEnabled() -> Bool { enabled }
    }

    @MainActor private final class IncompleteAXElement {
        @objc func accessibilityRole() -> NSAccessibility.Role? { .textField }
    }

    @MainActor private final class CanonicalNativeFixture {
        let window: NSWindow
        let control: CanonicalNativeControl
        let leaf: CanonicalAXLeaf
        let driver: ProductionVisualSourcesDriver
        let output: URL
        var input: [String: Any]?
        private let application: NativePointerApplicationLease
        let context: NativePointerFixtureContext
        init(_ name: String) async throws {
            try #require(ProcessInfo.processInfo.arguments.contains("--no-parallel"))
            let events = try #require(ProcessInfo.processInfo.environment["NGV_APPKIT_TEST_EVENTS"])
            let folder = URL(fileURLWithPath: events).deletingLastPathComponent()
                .appendingPathComponent("native-pointer-canonical-" + name + "-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let acquiredApplication = try await NativePointerApplicationLease.acquire(); application = acquiredApplication; let created = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 140),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 140))
            let native = CanonicalNativeControl(frame: NSRect(x: 30, y: 40, width: 180, height: 36))
            let canonical = CanonicalAXLeaf(window: created, frame: .zero)
            native.canonicalHit = canonical
            root.addSubview(native)
            created.contentView = root
            created.isReleasedWhenClosed = false
            window = created
            control = native
            leaf = canonical
            output = folder
            driver = ProductionVisualSourcesDriver(window: created, output: folder, name: name); context = try NativePointerFixtureContext.owned(window: created, application: acquiredApplication, output: folder)


            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            root.layoutSubtreeIfNeeded()
        }

        func ready() async throws {
            try await context.wait("canonical native fixture", driver: driver, clauses: ["active", "key", "presentation", "control-window"]) {
                self.context.operand("active", NSApp.isActive) && self.context.operand("key", self.window.isKeyWindow) && self.context.operand("presentation", nativePointerWindowPresented(self.window)) && self.context.operand("control-window", self.control.window === self.window)
            }
            reset()
        }

        func reset() {
            control.isEnabled = true
            control.canonicalHit = leaf
            leaf.roleValue = .textField
            leaf.enabled = true
            leaf.parentElement = window
            leaf.measuredFrame = window.convertToScreen(control.convert(control.bounds, to: nil))
            input = nil
        }

        func click() async throws {
            let token = try NativeAcceptancePointer.claim()
            defer { NativeAcceptancePointer.release(token) }
            try await NativeAcceptancePointer.click(control, window: window, fraction: NSPoint(x: 0.5, y: 0.5),
                                                    token: token) { self.input = $0 }
        }

        func record(_ name: String, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                .write(to: output.appendingPathComponent(name + ".json"), options: .atomic)
        }

        func close() {
            context.close(); leaf.parentElement = nil
            control.canonicalHit = nil
            window.contentView = nil
            window.close()
            application.close(); context.applicationRestored()
        }
    }

    @Test func canonicalNativeAccessibilityHitKeepsSystemInputAndRealFieldFocus() async throws {
        try await exerciseTabTraversal()
        let fixture = try await CanonicalNativeFixture("input")
        defer { fixture.close() }
        try await fixture.ready()
        #expect(fixture.control.accessibilityRole()?.rawValue == kAXUnknownRole)
        let label = CanonicalAXLeaf(window: fixture.window, frame: fixture.leaf.measuredFrame)
        label.roleValue = .staticText
        label.enabled = false
        label.parentElement = fixture.leaf
        fixture.control.canonicalHit = label
        let hit = fixture.control.accessibilityHitTest(NSPoint(x: fixture.leaf.measuredFrame.midX,
                                                              y: fixture.leaf.measuredFrame.midY)) as? CanonicalAXLeaf
        #expect(hit === label)
        let replacementLabel = CanonicalAXLeaf(window: fixture.window, frame: fixture.leaf.measuredFrame)
        replacementLabel.roleValue = .staticText
        replacementLabel.enabled = false
        replacementLabel.parentElement = fixture.leaf
        let witness = CanonicalChangeWitness()
        do {
            let number = fixture.window.windowNumber
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                let owned = event.windowNumber == number && (event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0) > 0
                MainActor.assumeIsolated {
                    if owned { fixture.control.canonicalHit = replacementLabel; witness.switched = true }
                }
                return event
            }
            defer { if let monitor { NSEvent.removeMonitor(monitor) } }
            try await fixture.click()
        }
        #expect(witness.switched)
        let input = try #require(fixture.input)
        let posted = try #require(input["posted"] as? [[String: Any]])
        #expect(input["status"] as? String == "delivered")
        #expect(input["targetKind"] as? String == "native-control")
        #expect(input["accessibilityRole"] as? String == kAXTextFieldRole)
        let tag = try #require(input["tag"] as? Int64)
        #expect(fixture.control.downTags == [tag])
        #expect(fixture.control.downWasPressed)
        #expect(fixture.control.upCount <= 1)
        #expect(posted.filter { $0["type"] as? UInt32 == CGEventType.leftMouseDown.rawValue }.count == 1)
        #expect(posted.filter { $0["type"] as? UInt32 == CGEventType.leftMouseUp.rawValue }.count == 1)
        #expect(input["buttonDownObserved"] as? Bool == true)
        #expect(input["buttonReleased"] as? Bool == true)
        try fixture.record("canonical-input", input)
        fixture.reset()
        let methodControl = MethodBasedAXElement(role: .textField, frame: fixture.leaf.measuredFrame, parent: fixture.window)
        let methodLabel = MethodBasedAXElement(role: .staticText, frame: fixture.leaf.measuredFrame, parent: methodControl)
        methodLabel.enabled = false
        #expect(!((methodControl as AnyObject) is any NSAccessibilityProtocol))
        fixture.control.canonicalHit = methodLabel
        try await fixture.click()
        let methodInput = try #require(fixture.input)
        #expect(methodInput["status"] as? String == "delivered")
        #expect(methodInput["accessibilityRole"] as? String == kAXTextFieldRole)
        #expect(fixture.control.downTags.count == 2)
        #expect(methodInput["buttonDownObserved"] as? Bool == true)
        #expect(methodInput["buttonReleased"] as? Bool == true)
        try fixture.record("method-based-input", methodInput)
        let real = try await Fixture("canonical-real-field")
        defer { real.close() }
        try await real.ready()
        let field = try verifySettledFieldInput(real)
        #expect(field["status"] as? String == "delivered")
        #expect(field["accessibilityRole"] as? String == kAXTextFieldRole)
        #expect(real.window.firstResponder is NSTextView)
    }
    @Test func canonicalNativeAccessibilityFailuresNeverPostDown() async throws {
        let fixture = try await CanonicalNativeFixture("refused")
        defer { fixture.close() }
        try await fixture.ready()
        let counter = DownCounter()
        defer { counter.close() }
        let foreign = NSWindow(contentRect: fixture.window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        defer { foreign.close() }
        var records: [[String: Any]] = []
        for invalid in ["nil", "nonaccessibility", "absent-role", "unknown-role", "unrecognized-role", "empty-role",
                        "disabled-view", "disabled-leaf", "empty-frame", "nonfinite-frame", "outside-hit",
                        "misses-point", "foreign-window", "cycle", "missing-parent", "group-without-control", "unknown-surface-leaf",
                        "method-only-disabled", "method-only-incomplete"] {
            fixture.reset()
            switch invalid {
            case "nil": fixture.control.canonicalHit = nil
            case "nonaccessibility": fixture.control.canonicalHit = "not-accessibility"
            case "absent-role": fixture.leaf.roleValue = nil
            case "unknown-role": fixture.leaf.roleValue = .init(rawValue: kAXUnknownRole)
            case "unrecognized-role": fixture.leaf.roleValue = .init(rawValue: "AXUnrecognizedFixtureRole")
            case "empty-role": fixture.leaf.roleValue = .init(rawValue: "")
            case "disabled-view": fixture.control.isEnabled = false
            case "disabled-leaf": fixture.leaf.enabled = false
            case "empty-frame": fixture.leaf.measuredFrame.size.width = 0
            case "nonfinite-frame": fixture.leaf.measuredFrame.origin.x = .nan
            case "outside-hit": fixture.leaf.measuredFrame = fixture.leaf.measuredFrame.insetBy(dx: -5, dy: -5)
            case "misses-point": fixture.leaf.measuredFrame.size.width = 2
            case "foreign-window": fixture.leaf.parentElement = foreign
            case "cycle": fixture.leaf.parentElement = fixture.leaf
            case "missing-parent": fixture.leaf.parentElement = nil
            case "method-only-disabled":
                let leaf = MethodBasedAXElement(role: .textField, frame: fixture.leaf.measuredFrame, parent: fixture.window)
                leaf.enabled = false
                fixture.control.canonicalHit = leaf
            case "method-only-incomplete": fixture.control.canonicalHit = IncompleteAXElement()
            case "group-without-control": fixture.leaf.roleValue = .group
            case "unknown-surface-leaf":
                let unknown = CanonicalAXLeaf(window: fixture.window, frame: fixture.leaf.measuredFrame)
                unknown.roleValue = .init(rawValue: kAXUnknownRole)
                unknown.parentElement = fixture.leaf
                fixture.control.canonicalHit = unknown
            default: Issue.record("Unknown canonical accessibility refusal case.")
            }
            do {
                try await fixture.click()
                Issue.record("An invalid canonical native accessibility target posted input: \(invalid)")
            } catch {
                if invalid == "method-only-disabled" || invalid == "method-only-incomplete" {
                    let failure = try #require(fixture.input?["accessibilityGuardFailure"] as? [String: Any])
                    #expect(failure["provided"] as? Bool == true)
                    #expect(failure["formalProtocolConformance"] as? Bool == false)
                    let ancestry = try #require(failure["ancestry"] as? [[String: Any]])
                    let original = try #require(ancestry.first)
                    #expect(original["roleGetter"] as? Bool == true)
                    #expect(original["role"] as? String == kAXTextFieldRole)
                    if invalid == "method-only-disabled" {
                        #expect((error as? GateBlocked)?.message == "The actual pointer control is disabled or has changed geometry.")
                        #expect(failure["type"] as? String == String(reflecting: MethodBasedAXElement.self))
                        #expect(original["frameGetter"] as? Bool == true)
                        #expect(original["enabledGetter"] as? Bool == true)
                        #expect(original["enabled"] as? Bool == false)
                    } else {
                        #expect((error as? GateBlocked)?.message == "The actual pointer control has incomplete accessibility getters.")
                        #expect(failure["type"] as? String == String(reflecting: IncompleteAXElement.self))
                        #expect(original["frameGetter"] as? Bool == false)
                        #expect(original["enabledGetter"] as? Bool == false)
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(counter.count == 0)
            #expect(fixture.control.downTags.isEmpty)
            #expect(!CGEventSource.buttonState(.combinedSessionState, button: .left))
            records.append(["case": invalid, "downs": counter.count])
        }
        fixture.reset()
        let cover = NSWindow(contentRect: fixture.window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = .windowBackgroundColor
        cover.ignoresMouseEvents = false
        cover.order(.above, relativeTo: fixture.window.windowNumber)
        defer { cover.close() }
        let point = NSPoint(x: fixture.leaf.measuredFrame.midX, y: fixture.leaf.measuredFrame.midY)
        try await fixture.driver.wait("canonical cover presentation") { nativePointerOverlayPresented(cover, above: fixture.window, at: point, receiver: cover) }
        try #require(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == cover.windowNumber)
        do {
            try await fixture.click()
            Issue.record("An input-catching window accepted a click through the original native target.")
        } catch {
            #expect(error.localizedDescription.contains("The original native window is covered at the pointer target."))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(counter.count == 0)
        #expect(fixture.control.downTags.isEmpty)
        #expect(!CGEventSource.buttonState(.combinedSessionState, button: .left))
        let input = try #require(fixture.input)
        let failure = try #require(input["windowGuardFailure"] as? [String: Any])
        #expect(failure["firstFailedClause"] as? String == "windowAtPointMatches")
        #expect(failure["windowAtPoint"] as? Int == cover.windowNumber)
        #expect(failure["originalWindowNumber"] as? Int == fixture.window.windowNumber)
        #expect(failure["ownerPID"] as? Int32 == getpid())
        #expect(failure["originalWindowMatchCount"] as? Int == 1)
        let clauses = try #require(failure["clauses"] as? [[String: String]])
        #expect(clauses.first == ["name": "windowAtPointMatches", "status": "FAIL"])
        #expect(clauses.count == 9 && clauses.dropFirst().allSatisfy { $0["status"] == "NOT_EVALUATED" })
        #expect(failure["screenPoint"] as? [CGFloat] == [point.x, point.y])
        #expect((input["posted"] as? [Any])?.isEmpty == true)
        #expect(input["ownedDownPosted"] as? Bool == false)
        records.append(["case": "covered-window", "downs": counter.count, "windowGuardFailure": failure])
        do {
            let token = try NativeAcceptancePointer.claim()
            defer { NativeAcceptancePointer.release(token) }
            try await NativeAcceptancePointer.click(fixture.control, window: fixture.window,
                fraction: NSPoint(x: 0.5, y: 0.5), token: token) { _ in throw CocoaError(.fileWriteNoPermission) }
            Issue.record("A covered native target accepted input when its failure recorder threw.")
        } catch {
            #expect(error.localizedDescription.contains("The original native window is covered at the pointer target."))
        }
        #expect(counter.count == 0)
        #expect(fixture.control.downTags.isEmpty)
        try fixture.record("canonical-refusals", ["cases": records])
    }

    @Test func canonicalNativeAccessibilityIdentityAndGeometryAreRevalidatedBeforeDown() async throws {
        try await verifyTransientWindowsSettleBeforeInput(); let fixture = try await CanonicalNativeFixture("revalidation")
        defer { fixture.close() }
        try await fixture.ready()
        let counter = DownCounter()
        defer { counter.close() }
        var records: [[String: Any]] = []
        for change in ["identity", "geometry", "enabled"] {
            fixture.reset()
            let replacement = CanonicalAXLeaf(window: fixture.window, frame: fixture.leaf.measuredFrame)
            let number = fixture.window.windowNumber
            let witness = CanonicalChangeWitness()
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                let owned = event.windowNumber == number && (event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0) > 0
                MainActor.assumeIsolated {
                    if owned {
                        witness.switched = true
                        if change == "identity" { fixture.control.canonicalHit = replacement }
                        else if change == "geometry" { fixture.leaf.measuredFrame.origin.x += 0.25 }
                        else { fixture.leaf.enabled = false }
                    }
                }
                return event
            }
            defer { if let monitor { NSEvent.removeMonitor(monitor) } }
            do {
                try await fixture.click()
                Issue.record("A changed canonical native accessibility target accepted Down: \(change)")
            } catch {}
            #expect(witness.switched)
            try await Task.sleep(for: .milliseconds(50))
            #expect(counter.count == 0)
            #expect(fixture.control.downTags.isEmpty)
            #expect(!CGEventSource.buttonState(.combinedSessionState, button: .left))
            let input = try #require(fixture.input)
            let posted = try #require(input["posted"] as? [[String: Any]])
            #expect(posted.contains { $0["type"] as? UInt32 == CGEventType.mouseMoved.rawValue })
            #expect(!posted.contains { $0["type"] as? UInt32 == CGEventType.leftMouseDown.rawValue })
            records.append(["case": change, "switched": witness.switched, "downs": counter.count])
            replacement.parentElement = nil
        }
        try fixture.record("canonical-revalidation", ["cases": records])

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 360),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let capture = Capture()
        sheet.isReleasedWhenClosed = false
        sheet.contentView = Hosting(rootView: Controls(capture: capture))
        fixture.window.beginSheet(sheet, completionHandler: nil)
        defer { fixture.window.endSheet(sheet); sheet.orderOut(nil) }
        let readySheet = try await fixture.driver.sheet("pointer.Undo", parent: fixture.window)
        try #require(readySheet === sheet && fixture.window.attachedSheet === sheet)
        let settled = try #require(fixture.driver.interactions.last { $0["label"] as? String == "native window presentation stable" }?["evidence"] as? [String: Any])
        #expect(settled["window"] as? Int == sheet.windowNumber)
        try await fixture.driver.click("pointer.Undo", in: readySheet)
        try await fixture.driver.wait("presented sheet delivered Undo") { capture.count("Undo") == 1 }
        let input = try #require(fixture.driver.interactions.last { $0["id"] as? String == "pointer.Undo" }?["nativeInput"] as? [String: Any])
        let callback = try #require(capture.callbacks.first)
        let tag = try #require(input["tag"] as? Int64)
        #expect(input["status"] as? String == "delivered")
        #expect(input["window"] as? Int == sheet.windowNumber)
        #expect(tag > 0 && callback["tag"] as? Int64 == tag)
        try fixture.record("presented-sheet-input", input)
    }

}

@MainActor private func nativePointerViewportReady(in window: NSWindow) -> Bool {
    guard let root = window.contentView,
          let field = WorkspaceUIAcceptance.findProbe(in: root, identifier: "pointer.field"),
          let clip = field.enclosingScrollView?.contentView else { return false }
    let frame = field.convert(field.bounds, to: clip)
    return [frame.minX, frame.minY, frame.width, frame.height, clip.bounds.width, clip.bounds.height].allSatisfy(\.isFinite)
        && frame.width > 0 && frame.height > 0 && clip.bounds.contains(frame)
}

@MainActor private struct NativePointerViewportStack<Content: View>: View {
    let content: Content
    @State private var width: CGFloat?

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.sm) { content }
            .frame(width: width)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                NativePointerViewportReader { measured in
                    if width != measured { width = measured }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

@MainActor private struct NativePointerViewportReader: NSViewRepresentable {
    let onWidth: (CGFloat) -> Void

    func makeNSView(context: Context) -> NativePointerViewportProbe {
        let view = NativePointerViewportProbe()
        view.configure(onWidth)
        return view
    }

    func updateNSView(_ view: NativePointerViewportProbe, context: Context) { view.configure(onWidth) }
    static func dismantleNSView(_ view: NativePointerViewportProbe, coordinator: ()) { view.stop() }
}

@MainActor private final class NativePointerViewportProbe: NSView {
    private weak var clip: NSClipView?
    private weak var ownerWindow: NSWindow?
    private var tokens: [NSObjectProtocol] = []
    private var callback: ((CGFloat) -> Void)?
    private var generation: UInt = 0
    private var scheduled = false
    private var lastWidth: CGFloat?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
    override func layout() { super.layout(); connect() }

    func configure(_ callback: @escaping (CGFloat) -> Void) {
        generation &+= 1; scheduled = false; lastWidth = nil
        self.callback = callback
        connect()
    }

    func stop() {
        disconnect()
        callback = nil
    }

    private func disconnect() {
        generation &+= 1; scheduled = false; lastWidth = nil
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []; clip = nil; ownerWindow = nil
    }

    private func connect() {
        guard callback != nil else { return }
        guard let window, let current = enclosingScrollView?.contentView else { disconnect(); return }
        if current !== clip || window !== ownerWindow {
            disconnect()
            clip = current; ownerWindow = window
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: current, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish() }
                })
            }
            current.postsBoundsChangedNotifications = true
            current.postsFrameChangedNotifications = true
        }
        publish()
    }

    private func publish() {
        guard callback != nil, !scheduled, let clip, let window = ownerWindow else { return }
        scheduled = true
        let currentGeneration = generation
        DispatchQueue.main.async { [weak self, weak clip, weak window] in
            guard let self, self.generation == currentGeneration else { return }
            self.scheduled = false
            guard self.callback != nil, let clip, let window, self.clip === clip, self.ownerWindow === window,
                  self.window === window, clip.window === window, self.enclosingScrollView?.contentView === clip else { return }
            let width = clip.bounds.width
            guard width.isFinite, width > 0, width != self.lastWidth else { return }
            self.lastWidth = width
            self.callback?(width)
        }
    }
}

@MainActor private func nativePointerWindowPresented(_ window: NSWindow, above original: NSWindow? = nil) -> Bool {
    guard window.isVisible, let screen = NSScreen.screens.first,
          let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
    let matches = rows.indices.filter { (rows[$0][kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
        && (rows[$0][kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }
    guard matches.count == 1, let index = matches.first,
          (rows[index][kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
          let alpha = (rows[index][kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha.isFinite, alpha > 0,
          let raw = rows[index][kCGWindowBounds as String] as? [String: Any],
          let actual = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
    let frame = window.frame
    let expected = CGRect(x: frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    guard [actual.minX, actual.minY, actual.width, actual.height, expected.minX, expected.minY, expected.width, expected.height].allSatisfy(\.isFinite),
          actual.width > 0, actual.height > 0, actual == expected else { return false }
    if let original {
        let below = rows.indices.filter { (rows[$0][kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
            && (rows[$0][kCGWindowNumber as String] as? NSNumber)?.intValue == original.windowNumber }
        return below.count == 1 && index < below[0]
    }
    return true
}

@MainActor private func nativePointerOverlayPresented(_ overlay: NSWindow, above original: NSWindow, at point: NSPoint?, receiver: NSWindow) -> Bool {
    guard let point, point.x.isFinite, point.y.isFinite else { return false }
    return NSApp.isActive && original.isKeyWindow && nativePointerWindowPresented(overlay, above: original)
        && NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == receiver.windowNumber
}

@MainActor private final class NativePointerFixtureContext {
    private let window: NSWindow
    private let output: URL
    private let previousMenu: NSMenu?
    private let menu: NSMenu
    private let application: NativePointerApplicationLease
    private var monitor: Any?
    private var closed = false
    private var keyEvents: [[String: Any]] = []
    private var droppedKeyEvents = 0
    private var snapshots: [[String: Any]] = []
    private var droppedSnapshots = 0
    private var readiness: [String: Any] = [:]
    private var clauses: [[String: Any]] = []
    private var evaluations = 0

    static func owned(window: NSWindow, application: NativePointerApplicationLease, output: URL) throws -> NativePointerFixtureContext {
        window.isReleasedWhenClosed = false
        do { return try NativePointerFixtureContext(window: window, application: application, output: output) }
        catch { window.contentView = nil; window.close(); application.close(); throw error }
    }

    private init(window: NSWindow, application: NativePointerApplicationLease, output: URL) throws {
        self.window = window; self.output = output.appendingPathComponent("fixture-context.json")
        previousMenu = application.previousMenu
        menu = application.menu; self.application = application
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let type = event.type.rawValue, number = event.windowNumber, code = event.keyCode
            let flags = event.modifierFlags.rawValue, timestamp = event.timestamp
            let characters = event.characters ?? "", ignoring = event.charactersIgnoringModifiers ?? ""
            MainActor.assumeIsolated { () -> Void in
                self?.receive(type: type, number: number, code: code, flags: flags, timestamp: timestamp,
                              characters: characters, ignoring: ignoring)
            }
            return event
        }
        do {
            guard monitor != nil else { throw CocoaError(.featureUnsupported) }
            try persist("menu-installed")
        } catch {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil

            closed = true
            throw error
        }
    }

    func wait(_ label: String, driver: ProductionVisualSourcesDriver, clauses names: [String], _ ready: () -> Bool) async throws {
        evaluations = 0; readiness = ["label": label, "origin": "ORIGINAL_READINESS_PREDICATE"]
        try persist("readiness-entry-additional")
        do {
            try await driver.wait(label) {
                self.evaluations += 1
                self.clauses = names.map { ["name": $0, "status": "NOT_EVALUATED"] }
                let result = ready()
                self.readiness["clauses"] = self.clauses; self.readiness["result"] = result
                self.readiness["evaluations"] = self.evaluations
                self.readiness["evaluatedAtUptime"] = ProcessInfo.processInfo.systemUptime
                return result
            }
        } catch {
            recordFailure("readiness-terminal-failure", error: error)
            throw error
        }
        try persist("readiness-success")
    }

    func operand(_ name: String, _ read: @autoclosure () -> Bool) -> Bool {
        let result = read()
        if let index = clauses.firstIndex(where: { $0["name"] as? String == name }) {
            clauses[index]["status"] = result ? "PASS" : "FAIL"
            clauses[index]["value"] = result
        }
        return result
    }

    func fill(_ id: String, value: String, driver: ProductionVisualSourcesDriver) async throws {
        try persist("fill-entry")
        do { try await driver.fill(id, value: value, in: window) }
        catch { recordFailure("fill-terminal-failure", error: error); throw error }
        try persist("fill-success")
    }

    private func receive(type: UInt, number: Int, code: UInt16, flags: UInt, timestamp: Double,
                         characters: String, ignoring: String) {
        guard !closed else { return }
        guard keyEvents.count < 128 else { droppedKeyEvents += 1; return }
        keyEvents.append(["origin": "LOCAL_KEY_MONITOR_PASS_THROUGH", "actualDispatchObserved": false,
            "type": type, "window": number, "matchesFixtureWindow": number == window.windowNumber,
            "keyCode": code, "modifiers": flags, "timestamp": timestamp,
            "characters": String(characters.prefix(64)), "charactersIgnoringModifiers": String(ignoring.prefix(64)),
            "charactersUTF16Length": (characters as NSString).length, "charactersTruncated": characters.count > 64 || ignoring.count > 64,
            "menuOwnedAtReceipt": NSApp.mainMenu === menu, "additionalFieldSnapshot": fieldSnapshot()])
    }

    private func identity(_ object: AnyObject?) -> [String: String] {
        guard let object else { return ["class": "nil", "identity": "nil"] }
        return ["class": String(describing: type(of: object)), "identity": String(describing: Unmanaged.passUnretained(object).toOpaque())]
    }

    private func fieldSnapshot() -> [String: Any] {
        let editor = window.firstResponder as? NSTextView
        var pending = window.contentView.map { [$0] } ?? [], owners: [[String: Any]] = [], visited = 0, ownerCount = 0
        var truncated = false
        while visited < 4096, let view = pending.popLast() {
            visited += 1
            if let editor, (view as? NSTextField)?.currentEditor() === editor || (view === editor && !editor.isFieldEditor) {
                ownerCount += 1
                if owners.count < 8 { owners.append(["object": identity(view), "currentEditor": identity((view as? NSTextField)?.currentEditor()),
                    "window": view.window?.windowNumber ?? -1]) }
            }
            let children = view.subviews, remaining = max(0, 4096 - visited - pending.count)
            truncated = truncated || children.count > remaining
            pending.append(contentsOf: children.prefix(remaining))
        }
        let selection = editor?.selectedRange()
        return ["origin": "ADDITIONAL_FIELD_OBSERVATION", "firstResponder": identity(window.firstResponder),
            "editor": identity(editor), "editorText": String((editor?.string ?? "").prefix(128)),
            "expectedSelectAllUTF16Length": editor.map { ($0.string as NSString).length } as Any? ?? NSNull(),
            "actualSelectedRange": selection.map { [$0.location, $0.length] } as Any? ?? NSNull(),
            "isEditable": editor?.isEditable as Any? ?? NSNull(), "isFieldEditor": editor?.isFieldEditor as Any? ?? NSNull(),
            "editorStillFirstResponder": editor.map { window.firstResponder === $0 } as Any? ?? NSNull(),
            "owners": owners, "ownerCount": ownerCount, "ownerLimitReached": ownerCount > 8,
            "viewLimitReached": truncated || !pending.isEmpty]
    }

    private func menuSnapshot() -> [String: Any] {
        let selectAll = #selector(NSText.selectAll(_:))
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }.filter { $0.action == selectAll }
        let actions: [[String: Any]] = items.prefix(64).map { item in
            let resolved = NSApp.target(forAction: selectAll, to: item.target, from: item).map { $0 as AnyObject }
            return ["action": NSStringFromSelector(selectAll), "keyEquivalent": item.keyEquivalent,
                "modifiers": item.keyEquivalentModifierMask.rawValue, "enabled": item.isEnabled,
                "declaredTarget": identity(item.target), "additionalResolvedTarget": identity(resolved)]
        }
        return ["origin": "ADDITIONAL_MENU_AND_TARGET_QUERY_NOT_ACTUAL_DISPATCH", "actualDispatchObserved": false,
            "installedMenu": identity(menu), "actualMenu": identity(NSApp.mainMenu), "owned": NSApp.mainMenu === menu,
            "selectAllMatches": items.count, "selectAllItems": actions, "itemLimitReached": items.count > 64]
    }

    private func snapshot(_ stage: String, error: String?) -> [String: Any] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let matches = rows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
            && ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }
        let cg: [[String: Any]] = matches.prefix(16).map { row in
            ["number": row[kCGWindowNumber as String] ?? NSNull(), "bounds": row[kCGWindowBounds as String] ?? NSNull(),
             "alpha": row[kCGWindowAlpha as String] ?? NSNull(), "onscreen": row[kCGWindowIsOnscreen as String] ?? NSNull()]
        }
        let undo = window.contentView.flatMap { WorkspaceUIAcceptance.findProbe(in: $0, identifier: "pointer.Undo") }
        return ["stage": stage, "error": error.map { String($0.prefix(2048)) } as Any? ?? NSNull(), "uptime": ProcessInfo.processInfo.systemUptime,
            "additionalObservationOrigin": "ADDITIONAL_TERMINAL_OR_PHASE_SNAPSHOT_NOT_PREDICATE_REEVALUATION",
            "active": NSApp.isActive, "activationPolicy": NSApp.activationPolicy().rawValue,
            "primaryScreenFrame": NSScreen.screens.first.map { NSStringFromRect($0.frame) } as Any? ?? NSNull(),
            "key": window.isKeyWindow, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
            "fixtureWindow": window.windowNumber, "visible": window.isVisible, "windowFrame": NSStringFromRect(window.frame),
            "CGMatchCount": matches.count, "CGWindows": cg, "CGWindowLimitReached": matches.count > 16,
            "undoProbe": identity(undo), "viewportReadyAdditional": nativePointerViewportReady(in: window),
            "field": fieldSnapshot(), "menu": menuSnapshot(), "lastOriginalReadinessEvaluation": readiness]
    }

    private func persist(_ stage: String, error: String? = nil) throws {
        if snapshots.count < 32 { snapshots.append(snapshot(stage, error: error)) } else { droppedSnapshots += 1 }
        let value: [String: Any] = ["schema": "native-pointer-fixture-context/v1", "snapshots": snapshots,
            "keyEvents": keyEvents, "droppedKeyEvents": droppedKeyEvents, "droppedSnapshots": droppedSnapshots,
            "keyMonitorReturnsOriginalEvent": true, "boundedDiagnosticQueriesAreAdditional": true,
            "closed": closed, "menuRestored": closed && NSApp.mainMenu === previousMenu,
            "policyRestored": closed && NSApp.activationPolicy() == application.previousPolicy,
            "originalPolicy": application.previousPolicy.rawValue]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output, options: .atomic)
    }

    private func recordFailure(_ stage: String, error: Error) {
        do { try persist(stage, error: error.localizedDescription) }
        catch { Issue.record("Native fixture evidence failed: \(error.localizedDescription)") }
    }

    func applicationRestored() {
        do { try persist("application-restored-after-window-close") } catch { Issue.record("Native fixture evidence failed: \(error.localizedDescription)") }
    }

    func close() {
        guard !closed else { return }
        do { try persist("cleanup-before-window-close") } catch { Issue.record("Native fixture evidence failed: \(error.localizedDescription)") }
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        let owned = NSApp.mainMenu === menu
        closed = true
        if !owned { Issue.record("The native fixture lost its owned main-menu context before cleanup.") }
        do { try persist("menu-released-before-window-close") } catch { Issue.record("Native fixture evidence failed: \(error.localizedDescription)") }
    }
}

@MainActor private final class NativePointerApplicationLease {
    private static var current: NativePointerApplicationLease?
    let previousMenu: NSMenu?
    let previousPolicy: NSApplication.ActivationPolicy
    let menu: NSMenu
    private let previousOwner: NativePointerApplicationLease?
    private var closed = false

    static func acquire() async throws -> NativePointerApplicationLease {
        let owner = current
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while NSApp.activationPolicy() == .prohibited && NSApp.isActive {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GateBlocked("The previous native fixture has not finished deactivating.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard current === owner else { throw GateBlocked("The native fixture application owner changed during preparation.") }
        let policy = NSApp.activationPolicy(), previousMenu = NSApp.mainMenu
        guard owner == nil || (NSApp.mainMenu === owner?.menu && policy == .regular) else { throw GateBlocked("The outer native fixture no longer owns its application context.") }
        if policy != .regular {
            guard NSApp.setActivationPolicy(.regular) else { throw GateBlocked("The native fixture could not acquire regular application policy.") }
        }
        let transitionMenu = NSApp.mainMenu
        do {
            while NSApp.activationPolicy() != .regular {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw GateBlocked("Regular native fixture policy did not become ready.") }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard current === owner, NSApp.mainMenu === transitionMenu, NSApp.activationPolicy() == .regular else { throw GateBlocked("The native fixture application context changed before menu construction.") }
            let lease = NativePointerApplicationLease(menu: previousMenu, policy: policy, owner: owner)
            current = lease
            return lease
        } catch {
            if current === owner && NSApp.mainMenu === transitionMenu && NSApp.activationPolicy() == .regular {
                if !NSApp.setActivationPolicy(policy) { Issue.record("The native fixture could not restore application policy after preparation failed.") }
                NSApp.mainMenu = previousMenu
            }
            throw error
        }
    }

    private init(menu previous: NSMenu?, policy: NSApplication.ActivationPolicy, owner: NativePointerApplicationLease?) {
        previousMenu = previous; previousPolicy = policy; previousOwner = owner
        let installed = NSMenu(), application = NSMenuItem()
        application.submenu = NSMenu(title: "NexGenVideo")
        installed.addItem(application); installed.addItem(MainMenuBuilder.editMenu()); menu = installed
        NSApp.mainMenu = installed
    }

    func close() {
        guard !closed else { return }; closed = true
        guard Self.current === self, NSApp.mainMenu === menu, NSApp.activationPolicy() == .regular else {
            Issue.record("The native fixture lost application policy or menu ownership before cleanup."); return
        }
        if previousPolicy != .regular && !NSApp.setActivationPolicy(previousPolicy) {
            Issue.record("The native fixture could not restore its original application policy."); return
        }
        NSApp.mainMenu = previousMenu
        Self.current = previousOwner
        if NSApp.activationPolicy() != previousPolicy || NSApp.mainMenu !== previousMenu {
            Issue.record("The native fixture did not restore its exact original application policy and menu.")
        }
    }
}

@MainActor private func nativePointerOwnedHostingAdmissionAssertions(window: NSWindow) throws {
    let root = try #require(window.contentView)
    let wrapper = NSView(frame: NSRect(x: 4, y: 4, width: 80, height: 60))
    let marker = NSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
    wrapper.addSubview(marker); root.addSubview(wrapper)
    defer { wrapper.removeFromSuperview() }
    let point = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
    func owner(_ hit: NSView, original: NSView? = nil, at location: NSPoint? = nil) -> NSView? {
        NativeAcceptancePointer.ownedHostingView(for: hit, probe: marker, root: original ?? root, window: window, point: location ?? point)
    }
    try #require(wrapper.window === window && marker.window === window)
    try #require(wrapper.isDescendant(of: root) && marker.isDescendant(of: wrapper))
    try #require(!wrapper.isHiddenOrHasHiddenAncestor && !wrapper.visibleRect.isEmpty)
    let bounds = marker.convert(marker.bounds, to: wrapper)
    let local = wrapper.convert(point, from: nil)
    try #require(wrapper.bounds.contains(bounds) && wrapper.visibleRect.contains(bounds))
    try #require(wrapper.bounds.contains(local) && wrapper.visibleRect.contains(local))
    #expect(owner(root) === root)
    #expect(owner(wrapper) === root)
    wrapper.setAccessibilityElement(false)
    wrapper.setAccessibilityEnabled(false)
    try #require(!wrapper.isAccessibilityElement() && !wrapper.isAccessibilityEnabled())
    #expect(owner(wrapper) === root)
    let sibling = NSView(frame: wrapper.frame); root.addSubview(sibling)
    defer { sibling.removeFromSuperview() }
    #expect(owner(sibling) == nil)
    #expect(owner(wrapper, original: sibling) == nil)
    #expect(owner(wrapper, at: NSPoint(x: -10000, y: -10000)) == nil)
    wrapper.isHidden = true; #expect(owner(wrapper) == nil); wrapper.isHidden = false
    let frame = marker.frame
    marker.setFrameOrigin(NSPoint(x: -1, y: 10)); #expect(owner(wrapper) == nil); marker.frame = frame
    let button = NSButton(frame: wrapper.bounds); wrapper.addSubview(button)
    button.addSubview(marker); marker.frame = frame
    #expect(owner(button) == nil)
    let child = NSView(frame: button.bounds); button.addSubview(child)
    marker.removeFromSuperview(); child.addSubview(marker); marker.frame = frame
    #expect(owner(child) == nil)
    button.isEnabled = false; #expect(owner(child) == nil)
    marker.removeFromSuperview(); wrapper.addSubview(marker); marker.frame = frame
    button.removeFromSuperview()
    let text = NSTextView(frame: wrapper.bounds), textChild = NSView(frame: wrapper.bounds)
    wrapper.addSubview(text); text.addSubview(textChild)
    marker.removeFromSuperview(); textChild.addSubview(marker); marker.frame = frame
    #expect(owner(textChild) == nil)
    marker.removeFromSuperview(); wrapper.addSubview(marker); marker.frame = frame
    text.removeFromSuperview()
    marker.removeFromSuperview(); #expect(owner(wrapper) == nil)
}

@MainActor private struct NativePointerViewportReadiness {
    @MainActor struct Sample {
        var fieldFrame: NSRect
        var clipBounds: NSRect
        var rootBounds: NSRect
        var windowFrame: NSRect
        var objects: [AnyObject]
        var windowNumber: Int
        var style: Int

        var identities: [ObjectIdentifier] { objects.map { ObjectIdentifier($0) } }

        static func current(in window: NSWindow) -> Self? {
            guard let root = window.contentView, root.window === window,
                  let field = WorkspaceUIAcceptance.findProbe(in: root, identifier: "pointer.field"),
                  let scroll = field.enclosingScrollView,
                  field.window === window, scroll.window === window else { return nil }
            let clip = scroll.contentView
            guard clip.window === window, let style = Int(exactly: scroll.scrollerStyle.rawValue) else { return nil }
            return Self(fieldFrame: field.convert(field.bounds, to: clip), clipBounds: clip.bounds,
                rootBounds: root.bounds, windowFrame: window.frame,
                objects: [window, root, field, scroll, clip],
                windowNumber: window.windowNumber, style: style)
        }

        func matches(_ other: Self) -> Bool {
            fieldFrame == other.fieldFrame && clipBounds == other.clipBounds && rootBounds == other.rootBounds
                && windowFrame == other.windowFrame && identities == other.identities
                && windowNumber == other.windowNumber && style == other.style
        }

        var isValid: Bool {
            let rectangles = [fieldFrame, clipBounds, rootBounds, windowFrame]
            return windowNumber > 0 && identities.count == 5
                && rectangles.allSatisfy { frame in
                    [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
                        && frame.width > 0 && frame.height > 0
                }
                && fieldFrame.width == clipBounds.width && clipBounds.contains(fieldFrame)
        }

        var evidence: [String: Any] {
            ["fieldFrame": NSStringFromRect(fieldFrame), "clipBounds": NSStringFromRect(clipBounds),
             "rootBounds": NSStringFromRect(rootBounds), "windowFrame": NSStringFromRect(windowFrame),
             "identities": identities.map { String(describing: $0) }, "window": windowNumber,
             "style": style, "valid": isValid]
        }
    }

    private var previous: Sample?
    private var began: TimeInterval?
    private var lastTime: TimeInterval?
    private var lastObserved: Sample?
    private var lastObservedAt: TimeInterval?
    private(set) var stableSeconds = 0.0
    private(set) var samples = 0

    mutating func reset() {
        previous = nil; began = nil; lastTime = nil
        stableSeconds = 0; samples = 0
    }

    mutating func observe(_ sample: Sample?, at time: TimeInterval) -> Bool {
        lastObserved = sample; lastObservedAt = time
        guard time.isFinite, time >= 0, let sample, sample.isValid else { reset(); return false }
        if previous?.matches(sample) != true || lastTime.map({ time < $0 }) == true {
            previous = sample; began = time; lastTime = time
            stableSeconds = 0; samples = 1
            return false
        }
        guard let began else { reset(); return false }
        lastTime = time; samples += 1; stableSeconds = time - began
        return stableSeconds >= 0.25
    }

    var evidence: [String: Any] {
        var result: [String: Any] = ["stableSeconds": stableSeconds, "samples": samples,
            "intervalActive": previous != nil, "lastObserved": lastObserved?.evidence ?? [:]]
        if let lastObservedAt {
            result["lastObservedUptime"] = lastObservedAt.isFinite ? lastObservedAt as Any : String(describing: lastObservedAt)
        }
        return result
    }
}

private extension NativePointerInteractionTests {
    @MainActor private final class CameraValues: ObservableObject {
        @Published var name = "Camera"
        @Published var fov = 50.0
        @Published var width = 1280
        @Published var untouched = 12
        @Published var height = 720
    }

    @MainActor private struct CameraFields: View {
        @ObservedObject var values: CameraValues

        var body: some View {
            VStack {
                TextField("Camera name", text: $values.name).background { marker("name", values.name) }
                LabeledContent("FOV") { TextField("Degrees", value: $values.fov, format: .number).background { marker("fov", String(values.fov)) } }
                LabeledContent("Width") { TextField("Pixels", value: $values.width, format: .number).background { marker("width", String(values.width)) } }
                LabeledContent("Other") { TextField("Pixels", value: $values.untouched, format: .number).background { marker("untouched", String(values.untouched)) } }
                LabeledContent("Height") { TextField("Pixels", value: $values.height, format: .number).background { marker("height", String(values.height)) } }
            }
            .padding(AppTheme.Spacing.md)
            .interfaceStyle()
        }

        private func marker(_ id: String, _ value: String) -> some View {
            AppRelaunchClickProbe(identifier: id, acceptanceState: true, acceptanceText: value).allowsHitTesting(false)
        }
    }

    @MainActor private final class TabWitness: NSObject {
        let window: NSWindow
        let values: CameraValues
        let fields: [String: NSTextField]
        let driver: ProductionVisualSourcesDriver
        var from = ""
        var start = 0
        var events: [String] = []
        var nameAtTab: [String] = []
        var fovAtTab: [Double] = []
        var earlyCompletion = false
        var coverWidth = false

        init(window: NSWindow, root: NSView, values: CameraValues, driver: ProductionVisualSourcesDriver) throws {
            self.window = window
            self.values = values
            self.driver = driver
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let editable = descendants(root).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            var fields: [String: NSTextField] = [:]
            for id in ["name", "fov", "width", "untouched", "height"] {
                let marker = try #require(WorkspaceUIAcceptance.findProbe(in: root, identifier: id))
                let frame = marker.convert(marker.bounds, to: root)
                let matches = editable.filter { $0.convert($0.bounds, to: root).contains(NSPoint(x: frame.midX, y: frame.midY)) }
                try #require(matches.count == 1)
                fields[id] = matches.first
            }
            self.fields = fields
            super.init()
        }

        func receive(_ type: UInt, code: UInt16, flags: UInt, point: NSPoint) {
            let editor = window.firstResponder as? NSTextView
            let owner = fields.first { editor != nil && $0.value.currentEditor() === editor }?.key ?? "none"
            if type == NSEvent.EventType.keyDown.rawValue, code == 48 {
                from = owner
                events.append("tab-down:" + owner)
                if owner == "name" {
                    nameAtTab.append(values.name)
                    if editor?.string != values.name || driver.text("name", in: window) != values.name {
                        events.append("name editor or probe differs at Tab")
                    }
                }
                if owner == "fov" {
                    fovAtTab.append(values.fov)
                    if editor?.string != "60.0" || driver.text("fov", in: window) != "60.0" {
                        events.append("FOV editor or probe differs at Tab")
                    }
                }
                if owner == "name" || owner == "fov" {
                    earlyCompletion = earlyCompletion || driver.interactions.dropFirst(start).contains {
                        ($0["field"] as? [String: Any])?["id"] as? String == owner
                    }
                }
            } else if type == NSEvent.EventType.keyUp.rawValue, code == 48 {
                events.append("tab-up:" + from)
            } else if type == NSEvent.EventType.keyDown.rawValue, code == 0,
                      NSEvent.ModifierFlags(rawValue: flags).contains(.command) {
                events.append("select:" + owner)
            } else if type == NSEvent.EventType.leftMouseDown.rawValue {
                for (id, field) in fields where field.convert(field.bounds, to: nil).contains(point) {
                    events.append("mouse:" + id)
                }
            }
        }

        @objc func editing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let id = fields.first(where: { $0.value === field })?.key else { return }
            if notification.name == NSControl.textDidBeginEditingNotification {
                events.append("begin:" + id)
            } else {
                let movement = (notification.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
                events.append(movement == NSTextMovement.tab.rawValue ? "tab-end:" + id : "end:" + id)
                if coverWidth, id == "fov", let width = fields["width"], let root = window.contentView {
                    let cover = NSButton(title: "Other control", target: nil, action: nil)
                    cover.refusesFirstResponder = true
                    cover.frame = width.convert(width.bounds, to: root)
                    root.addSubview(cover)
                }
            }
        }
    }

    private func exerciseTabTraversal() async throws {
        let fixture = try await CanonicalNativeFixture("tab-traversal")
        defer { fixture.close() }
        try await fixture.ready()
        let window = fixture.window, values = CameraValues()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 320))
        let host = NSHostingView(rootView: CameraFields(values: values))
        host.frame = root.bounds
        root.addSubview(host)
        window.setContentSize(root.bounds.size)
        window.contentView = root
        window.center()
        try await fixture.driver.wait("camera fields presented") {
            root.layoutSubtreeIfNeeded()
            return nativePointerWindowPresented(window) && WorkspaceUIAcceptance.probeFrame(identifier: "height", in: window) != nil
        }
        window.recalculateKeyViewLoop()
        let observer = try TabWitness(window: window, root: root, values: values, driver: fixture.driver)
        let center = NotificationCenter.default
        for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification] {
            center.addObserver(observer, selector: #selector(TabWitness.editing(_:)), name: name, object: nil)
        }
        defer { center.removeObserver(observer) }
        let number = window.windowNumber
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { event in
            if event.windowNumber == number {
                let type = event.type.rawValue, flags = event.modifierFlags.rawValue, point = event.locationInWindow
                let code: UInt16 = event.type == .leftMouseDown ? 0 : event.keyCode
                MainActor.assumeIsolated { observer.receive(type, code: code, flags: flags, point: point) }
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        try #require(monitor != nil && window.makeFirstResponder(nil))
        observer.start = fixture.driver.interactions.count
        try await fixture.driver.fillFields([("name", "Wide camera"), ("fov", "60.0"),
                                             ("width", "641"), ("height", "360")], in: window)
        try await fixture.driver.wait("last camera field finished editing") { observer.events.contains("tab-end:height") }
        #expect(values.name == "Wide camera" && values.fov == 60 && values.width == 641 && values.height == 360)
        #expect(values.untouched == 12)
        #expect(observer.nameAtTab == ["Wide camera"] && observer.fovAtTab == [60] && !observer.earlyCompletion)
        #expect(!observer.events.contains("name editor or probe differs at Tab"))
        #expect(!observer.events.contains("FOV editor or probe differs at Tab"))
        #expect(!observer.events.contains("mouse:fov") && !observer.events.contains("mouse:width"))
        func precedes(_ first: String, _ second: String) throws {
            let a = try #require(observer.events.firstIndex(of: first))
            let b = try #require(observer.events.firstIndex(of: second))
            #expect(a < b)
        }
        try precedes("mouse:name", "select:name")
        try precedes("mouse:height", "select:height")
        for (id, next) in [("name", "select:fov"), ("fov", "select:width"), ("width", "mouse:height"), ("height", "")] {
            try precedes("select:" + id, "tab-down:" + id)
            for completion in ["tab-up:" + id, "tab-end:" + id] {
                try precedes("tab-down:" + id, completion)
                if !next.isEmpty { try precedes(completion, next) }
            }
        }

        try #require(window.makeFirstResponder(nil))
        observer.coverWidth = true
        observer.events = []
        observer.start = fixture.driver.interactions.count
        do {
            try await fixture.driver.fillFields([("fov", "60.0"), ("width", "128")], in: window)
            Issue.record("The covered Width field received input.")
        } catch {
            #expect((error as? GateBlocked)?.message == "The text field is covered or has lost its editor.")
        }
        #expect(observer.fovAtTab == [60, 60] && !observer.earlyCompletion)
        #expect(observer.events.contains("tab-end:fov"))
        #expect(!observer.events.contains("FOV editor or probe differs at Tab"))
        #expect(!observer.events.contains("mouse:width") && !observer.events.contains("select:width"))
        #expect(values.width == 641)
    }
}

extension NativePointerInteractionTests {
    private func verifyWheelTargetingInSceneViewport() async throws {
        try await verifyRevealOfReplacedLazyControls()
        try await verifyReflowAfterRevealIsRevealedAgain()
        let outer = NSScrollView(), inner = NSScrollView()
        let outerDocument = NSView(), innerDocument = NSView()
        outer.documentView = outerDocument
        outerDocument.addSubview(inner)
        inner.documentView = innerDocument
        #expect(ProductionVisualSourcesDriver.ownsWheelHit(outerDocument, scroll: outer))
        #expect(ProductionVisualSourcesDriver.ownsWheelHit(inner, scroll: inner))
        #expect(ProductionVisualSourcesDriver.ownsWheelHit(innerDocument, scroll: inner))
        #expect(!ProductionVisualSourcesDriver.ownsWheelHit(innerDocument, scroll: outer))
        #expect(!ProductionVisualSourcesDriver.ownsWheelHit(inner, scroll: outer))
        let target = CGRect(x: 10, y: 662, width: 128, height: 48)
        for flipped in [true, false] {
            for initialOrigin in [CGFloat(0.5), 431.5, 472.5, 890.5] {
                var viewport = CGRect(x: 0, y: initialOrigin, width: 378, height: 217)
                var prior: ProductionVisualSourcesDriver.WheelResponse?
                for _ in 0..<6 {
                    if viewport.contains(target) { break }
                    let delta = ProductionVisualSourcesDriver.revealWheelDelta(
                        distance: target.midY - viewport.midY, flipped: flipped, viewport: viewport.height, prior: prior)
                    let origin = viewport.minY
                    let travel = CGFloat(delta) * 4.43 * (flipped ? -1 : 1)
                    viewport.origin.y = min(891.5, max(0.5, origin + travel))
                    prior = .init(delta: delta, displacement: viewport.minY - origin)
                }
                #expect(viewport.contains(target))
            }
        }
    }

    private func verifySettledFieldInput(_ real: Fixture) throws -> [String: Any] {
        let field = try real.input("field")
        let events = real.driver.interactions
        let presentationIndex = try #require(events.lastIndex {
            $0["label"] as? String == "text field presentation"
                && ($0["evidence"] as? [String: Any])?["id"] as? String == "pointer.field"
        })
        let pointerIndex = try #require(events.lastIndex { $0["kind"] as? String == "pointer" && $0["id"] as? String == "pointer.field" })
        #expect(presentationIndex < pointerIndex)
        let sampled = try #require((events[presentationIndex]["evidence"] as? [String: Any])?["target"] as? [String: Any])
        let original = try #require((field["preDownGuard"] as? [String: Any])?["originalTarget"] as? [String: Any])
        let clips = try #require(sampled["clippingAncestors"] as? [[String: Any]])
        #expect(!clips.isEmpty)
        for key in ["probeObject", "fieldOwner", "accessibilityObject", "accessibilityFrame", "probeFrame", "clippingAncestors"] {
            let measured = try #require(sampled[key] as? NSObject)
            let atMovement = try #require(original[key] as? NSObject)
            #expect(measured.isEqual(atMovement))
        }
        return field
    }
}

extension NativePointerInteractionTests {
    @MainActor private struct LazyBoard: View {
        let shots: [String]
        let target: String
        let capture: Capture

        private func marker(_ id: String, text: String? = nil) -> some View {
            AppRelaunchClickProbe(identifier: id, acceptanceState: true, acceptanceText: text).allowsHitTesting(false)
        }

        var body: some View {
            VStack {
                ScrollView {
                    Text("Other panel").background { marker("storyboard.sketch.sources." + target) }
                }.frame(height: 52)
                ScrollView {
                    LazyVStack {
                        ForEach(shots, id: \.self) { shot in
                            VStack {
                                Text(shot)
                                Menu("Other sketch sources") {
                                    Button("Capture frame") { capture.clicked(shot) }
                                }.background { marker("storyboard.sketch.sources." + shot) }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: shot == shots.first ? 780 : 260)
                            .background { marker("storyboard.plan." + shot) }
                        }
                    }.background { marker("storyboard.board.content", text: "saved-board") }
                }
            }.background { marker("storyboard.v2.workspace", text: "saved-board") }
        }
    }

    private func verifyLazyStoryboardMenu() async throws {
        let fixture = try await Fixture("lazy-board")
        defer { fixture.close() }
        let shots = (0..<14).map { "shot-" + String($0) }
        let target = shots[8]
        let control = "storyboard.sketch.sources." + target
        fixture.window.contentView = NSHostingView(rootView: LazyBoard(shots: shots, target: target, capture: fixture.capture))
        let driver = fixture.driver, window = fixture.window
        try await driver.waitForPresentation(of: window, control: "storyboard.board.content")
        #expect(driver.state(control, in: window) == nil)
        try await driver.revealStoryboardMoment(control, shotID: target, orderedShots: shots, fingerprint: "saved-board")
        try await driver.menu(control, title: "Capture frame", in: window)
        try await driver.wait("saved shot menu callback") { fixture.capture.count(target) == 1 }
        #expect(driver.interactions.contains { $0["label"] as? String == "native Board scroll towards saved shot" })
        #expect(shots.filter { fixture.capture.count($0) > 0 } == [target])
    }
}

extension NativePointerInteractionTests {
    private func verifyPermanentCoverRefusal(_ error: Error, cover: NSWindow, driver: ProductionVisualSourcesDriver) throws {
        #expect((error as? GateBlocked)?.message == "The original native window is covered at the pointer target.")
        let refused = try #require(driver.interactions.last { $0["kind"] as? String == "pointer" && $0["id"] as? String == "pointer.Undo" })
        let settle = try #require(refused["settle"] as? [String: Any])
        #expect(settle["verdict"] as? String == "covered")
        #expect(((settle["final"] as? [String: Any])?["windowAtPoint"] as? Int) == cover.windowNumber)
        #expect((settle["waitedSeconds"] as? Double ?? .infinity) < NativeInputSettling.limitSeconds / 2)
    }

    private func verifyInputSettlingDecisions() {
        typealias Settling = NativeInputSettling
        let target = 393, sheet = 406
        func sample(_ windows: [Settling.Window], at point: Int?, owned: Bool = true, active: Bool = true,
                    clipped: Bool = false, probe: Bool = true) -> Settling.Sample {
            var value = Settling.Sample()
            value.windows = [.init(number: target, bounds: CGRect(x: 152, y: 110, width: 720, height: 500), alpha: 1, leaving: false)] + windows
            value.targetWindow = target
            value.targetFrame = CGRect(x: 152, y: 158, width: 720, height: 500)
            value.targetActive = active
            value.pointWindow = point
            value.pointWindowOwned = owned
            value.probeExpected = true
            value.probe = probe ? ObjectIdentifier(Settling.self) : nil
            value.geometry = [CGRect(x: 14, y: 441, width: 61, height: 42)]
            value.clipped = clipped
            return value
        }
        func run(_ samples: [(TimeInterval, Settling.Sample)]) -> [Settling.Decision] {
            var settling = Settling()
            return samples.map { settling.observe($0.1, at: $0.0) }
        }
        func sheetWindow(y: CGFloat, leaving: Bool) -> Settling.Window {
            .init(number: sheet, bounds: CGRect(x: 152, y: y, width: 720, height: 500), alpha: 1, leaving: leaving)
        }

        let presenting = run([(0, sample([sheetWindow(y: 109, leaving: false)], at: target)),
                              (0.2, sample([sheetWindow(y: 109, leaving: false)], at: target)),
                              (0.24, sample([sheetWindow(y: 110, leaving: false)], at: target)),
                              (0.4, sample([sheetWindow(y: 110, leaving: false)], at: target)),
                              (0.5, sample([sheetWindow(y: 110, leaving: false)], at: target))])
        #expect(presenting.prefix(4).allSatisfy { $0 == .wait(Settling.changing) } && presenting.last == .settled)

        let dismissing = run([(0, sample([sheetWindow(y: 78, leaving: true)], at: sheet)),
                              (0.6, sample([sheetWindow(y: 78, leaving: true)], at: sheet)),
                              (0.7, sample([], at: target)),
                              (0.9, sample([], at: target)),
                              (0.96, sample([], at: target))])
        #expect(dismissing.prefix(2).allSatisfy { $0 == .wait(Settling.leavingCover) })
        #expect(dismissing[2] == .wait(Settling.changing) && dismissing[3] == .wait(Settling.changing) && dismissing[4] == .settled)

        let permanent = run([(0, sample([sheetWindow(y: 110, leaving: false)], at: sheet)),
                             (0.2, sample([sheetWindow(y: 110, leaving: false)], at: sheet)),
                             (0.3, sample([sheetWindow(y: 110, leaving: false)], at: sheet))])
        #expect(permanent == [.wait(Settling.changing), .wait(Settling.changing), .covered(sheet)])
        let foreign = run([(0, sample([], at: 77, owned: false)), (0.3, sample([], at: 77, owned: false))])
        #expect(foreign.last == .covered(77))
        let reflow = run([(0, sample([], at: target)), (0.1, sample([], at: target, clipped: true)),
                          (0.3, sample([], at: target, clipped: true)), (0.36, sample([], at: target, clipped: true))])
        #expect(reflow.dropLast().allSatisfy { $0 == .wait(Settling.changing) } && reflow.last == .reveal)
        #expect(run([(0, sample([], at: target, active: false)), (0.3, sample([], at: target, active: false))]).last == .inactive)
        #expect(run([(0, sample([], at: nil, probe: false)), (0.3, sample([], at: nil, probe: false))]).last == .missing)

        var restarted = Settling()
        _ = restarted.observe(sample([], at: target, clipped: true), at: 0)
        #expect(restarted.observe(sample([], at: target, clipped: true), at: 0.3) == .reveal)
        restarted.reset()
        #expect(restarted.observe(sample([], at: target), at: 0.31) == .wait(Settling.changing))
        #expect(restarted.observe(sample([], at: target), at: 0.6) == .settled)
    }

    @MainActor private final class ClosingWindow: NSWindow {
        // Reports what AppKit reports for a dismissed sheet that is still on screen.
        override var isSheet: Bool { true }
    }

    private func verifyTransientWindowsSettleBeforeInput() async throws {
        verifyInputSettlingDecisions()
        let fixture = try await Fixture("transient-windows")
        defer { fixture.close() }
        try await fixture.ready(unobscured: ["Undo"])
        let window = fixture.window, driver = fixture.driver
        func pointer(_ id: String) throws -> [String: Any] {
            try #require(driver.interactions.last { $0["kind"] as? String == "pointer" && $0["id"] as? String == id })
        }
        func movements() throws -> Int {
            let target = try fixture.point("Undo"), location = NSEvent.mouseLocation
            return abs(location.x - target.x) < 0.5 && abs(location.y - target.y) < 0.5 ? 2 : 1
        }
        func downUptime(_ entry: [String: Any]) -> Double? {
            ((entry["nativeInput"] as? [String: Any])?["posted"] as? [[String: Any]])?
                .first { $0["type"] as? UInt32 == CGEventType.leftMouseDown.rawValue }?["postedUptime"] as? Double
        }

        // The target window moves for a known time; input must bind only after it stopped.
        try await fixture.moveAway()
        let origin = window.frame.origin
        let moving = Task { @MainActor in
            for step in 1...25 {
                window.setFrameOrigin(NSPoint(x: origin.x + CGFloat(step), y: origin.y))
                try? await Task.sleep(for: .milliseconds(20))
            }
            return ProcessInfo.processInfo.systemUptime
        }
        var expected = try movements()
        try await driver.click("pointer.Undo", in: window)
        let stopped = await moving.value
        try await driver.wait("Undo after the window stopped") { fixture.capture.count("Undo") == 1 }
        try delivered("Undo", in: fixture, movements: expected)
        let moved = try pointer("pointer.Undo")
        let finalBounds = try #require(nativePointerCGBounds(window))
        let bound = try #require(((moved["nativeInput"] as? [String: Any])?["preDownGuard"] as? [String: Any])?["originalTarget"] as? [String: Any])
        #expect(bound["windowBounds"] as? [CGFloat] == [finalBounds.minX, finalBounds.minY, finalBounds.width, finalBounds.height])
        #expect((downUptime(moved) ?? 0) > stopped)
        #expect(((moved["settle"] as? [String: Any])?["changes"] as? Int ?? 0) > 0)

        // An app window that is closing covers the point for a known time; input must wait until it is gone.
        let cover = ClosingWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = .windowBackgroundColor
        cover.order(.above, relativeTo: window.windowNumber)
        defer { cover.close() }
        let undo = try fixture.point("Undo")
        try await driver.wait("closing window over Undo") { nativePointerOverlayPresented(cover, above: window, at: undo, receiver: cover) }
        let leaving = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            cover.orderOut(nil)
            return ProcessInfo.processInfo.systemUptime
        }
        expected = try movements()
        try await driver.click("pointer.Undo", in: window)
        let left = await leaving.value
        try await driver.wait("Undo after the closing window left") { fixture.capture.count("Undo") == 2 }
        try delivered("Undo", in: fixture, movements: expected)
        let waited = try pointer("pointer.Undo")
        let waitedSettle = try #require(waited["settle"] as? [String: Any])
        #expect((downUptime(waited) ?? 0) > left)
        #expect((waitedSettle["transitions"] as? [[String: Any]])?.contains { $0["leavingWindow"] as? Int == cover.windowNumber } == true)

        // A closing window that never leaves must end the bounded wait covered and refuse input.
        cover.order(.above, relativeTo: window.windowNumber)
        try await driver.wait("lingering closing window over Undo") { nativePointerOverlayPresented(cover, above: window, at: undo, receiver: cover) }
        driver.settleLimit = 1
        defer { driver.settleLimit = NativeInputSettling.limitSeconds }
        do {
            try await driver.click("pointer.Undo", in: window)
            Issue.record("A closing window that never left accepted a click through to the original window.")
        } catch {
            #expect((error as? GateBlocked)?.message == "The original native window is covered at the pointer target.")
        }
        let lingering = try #require(try pointer("pointer.Undo")["settle"] as? [String: Any])
        #expect(lingering["verdict"] as? String == "covered" && lingering["lastWait"] as? String == NativeInputSettling.leavingCover)
        #expect((lingering["waitedSeconds"] as? Double ?? 0) >= 1)
        #expect(fixture.capture.count("Undo") == 2)
        cover.orderOut(nil)
        driver.settleLimit = NativeInputSettling.limitSeconds

        // A real sheet is delivered at its final bounds; AppKit's dismissal state is checked only when it is observed.
        let sheetCapture = Capture()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 360),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = Hosting(rootView: Controls(capture: sheetCapture))
        defer {
            if window.attachedSheet === sheet { window.endSheet(sheet) }
            sheet.orderOut(nil)
        }
        window.beginSheet(sheet, completionHandler: nil)
        try await driver.click("pointer.Undo", in: sheet)
        try await driver.wait("sheet delivered Undo") { sheetCapture.count("Undo") == 1 }
        let presented = try pointer("pointer.Undo")
        let sheetBounds = try #require(nativePointerCGBounds(sheet))
        let sheetTarget = try #require(((presented["nativeInput"] as? [String: Any])?["preDownGuard"] as? [String: Any])?["originalTarget"] as? [String: Any])
        #expect((presented["nativeInput"] as? [String: Any])?["window"] as? Int == sheet.windowNumber)
        #expect(sheetTarget["windowBounds"] as? [CGFloat] == [sheetBounds.minX, sheetBounds.minY, sheetBounds.width, sheetBounds.height])
        let sheetPoint = NSPoint(x: sheetBounds.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - sheetBounds.midY)
        window.endSheet(sheet)
        let observedLeaving = NSWindow.windowNumber(at: sheetPoint, belowWindowWithWindowNumber: 0) == sheet.windowNumber
        if observedLeaving { #expect(sheet.isSheet && sheet.sheetParent?.attachedSheet !== sheet) }
        expected = try movements()
        try await driver.click("pointer.Undo", in: window)
        try await driver.wait("parent Undo after the sheet closed") { fixture.capture.count("Undo") == 3 }
        try delivered("Undo", in: fixture, movements: expected)
        #expect(sheetCapture.count("Undo") == 1)

        try await verifySegmentPointIsSettledAndUncovered(fixture)
        try fixture.record("transient-windows", ["moved": moved, "waited": waited, "presented": presented,
            "observedLeavingSheet": observedLeaving, "afterSheet": try pointer("pointer.Undo")])
    }

    @MainActor private final class SegmentModel: ObservableObject {
        @Published var mode = "Clay"
    }

    @MainActor private struct SegmentChoice: View {
        @ObservedObject var model: SegmentModel

        var body: some View {
            VStack {
                Picker("Mode", selection: $model.mode) {
                    Text("Clay").tag("Clay")
                    Text("Render").tag("Render")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .background {
                    AppRelaunchClickProbe(identifier: "segment.mode", acceptanceState: true, acceptanceText: model.mode)
                        .allowsHitTesting(false)
                }
                Spacer()
            }
            .padding(AppTheme.Spacing.md)
            .interfaceStyle()
        }
    }

    private func verifySegmentPointIsSettledAndUncovered(_ fixture: Fixture) async throws {
        let window = fixture.window, driver = fixture.driver, model = SegmentModel()
        window.contentView = NSHostingView(rootView: SegmentChoice(model: model))
        try await driver.waitForPresentation(of: window, control: "segment.mode")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(try #require(window.contentView)).compactMap { $0 as? NSSegmentedControl }
        let control = try #require(controls.count == 1 ? controls.first : nil)
        let screenFrame = window.convertToScreen(control.convert(control.bounds, to: nil))
        // Only the Render segment is covered; the control centre stays exposed.
        let cover = NSWindow(contentRect: NSRect(x: screenFrame.minX + screenFrame.width * 0.6, y: screenFrame.minY - 4,
                                                 width: screenFrame.width * 0.4 + 4, height: screenFrame.height + 8),
                             styleMask: .borderless, backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = .windowBackgroundColor
        cover.order(.above, relativeTo: window.windowNumber)
        defer { cover.close() }
        let render = NSPoint(x: screenFrame.minX + screenFrame.width * 0.75, y: screenFrame.midY)
        let centre = NSPoint(x: screenFrame.midX, y: screenFrame.midY)
        try await driver.wait("Render segment covered") {
            window.isKeyWindow && NSWindow.windowNumber(at: render, belowWindowWithWindowNumber: 0) == cover.windowNumber
                && NSWindow.windowNumber(at: centre, belowWindowWithWindowNumber: 0) == window.windowNumber
        }
        do {
            try await driver.segment("segment.mode", title: "Render", titles: ["Clay", "Render"], in: window)
            Issue.record("A covered segment received input.")
        } catch {
            #expect((error as? GateBlocked)?.message == "The actual segment cannot receive pointer input: Render")
        }
        #expect(model.mode == "Clay" && control.selectedSegment == 0)
        cover.orderOut(nil)
        try await driver.segment("segment.mode", title: "Render", titles: ["Clay", "Render"], in: window)
        #expect(model.mode == "Render")
        let pointer = try #require(driver.interactions.last { $0["kind"] as? String == "pointer" && $0["id"] as? String == "segment.mode" })
        #expect((pointer["segmentSettle"] as? [String: Any])?["verdict"] as? String == "settled")
    }

    @MainActor private final class ReflowModel: ObservableObject {
        @Published var viewport: CGFloat = 200
        @Published var text = "0"
    }

    @MainActor private struct ReflowField: View {
        @ObservedObject var model: ReflowModel

        var body: some View {
            VStack {
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.sm) {
                        Color.clear.frame(height: 140)
                        TextField("Camera name", text: $model.text).background {
                            AppRelaunchClickProbe(identifier: "reflow.field", acceptanceState: true, acceptanceText: model.text)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                }
                .frame(height: model.viewport)
                Spacer()
            }
            .interfaceStyle()
        }
    }

    private func verifyReflowAfterRevealIsRevealedAgain() async throws {
        let fixture = try await Fixture("reflow-after-reveal")
        defer { fixture.close() }
        let model = ReflowModel()
        let window = fixture.window, driver = fixture.driver
        window.contentView = NSHostingView(rootView: ReflowField(model: model))
        try await driver.waitForPresentation(of: window, control: "reflow.field")
        let field = try #require(window.contentView.flatMap { WorkspaceUIAcceptance.findProbe(in: $0, identifier: "reflow.field") })
        let clip = try #require(field.enclosingScrollView?.contentView)
        try #require(clip.bounds.contains(field.convert(field.bounds, to: clip)))
        // The viewport shrinks only once the driver is settling the already revealed field.
        let reflow = Task { @MainActor in
            while !Task.isCancelled {
                if driver.stage == "settle reflow.field" {
                    model.viewport = 150
                    return true
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        defer { reflow.cancel() }
        try await driver.fill("reflow.field", value: "Wide", in: window)
        let reflowed = await reflow.value
        #expect(reflowed)
        #expect(model.text == "Wide")
        let presentation = try #require(driver.interactions.last {
            $0["label"] as? String == "text field presentation" && ($0["evidence"] as? [String: Any])?["id"] as? String == "reflow.field"
        })
        let settle = try #require((presentation["evidence"] as? [String: Any])?["settle"] as? [String: Any])
        let reveals = try #require(settle["reveals"] as? [[String: Any]])
        #expect(settle["verdict"] as? String == "settled" && reveals.count == 1)
        #expect(((reveals.first?["sample"] as? [String: Any])?["clipped"] as? Bool) == true)
        #expect(clip.bounds.contains(field.convert(field.bounds, to: clip)))

        // A layout that never stops changing must exhaust the bounded wait and refuse input.
        driver.settleLimit = 1
        defer { driver.settleLimit = NativeInputSettling.limitSeconds }
        model.viewport = 200
        try await driver.waitForPresentation(of: window, control: "reflow.field")
        let churn = Task { @MainActor in
            var step = 0
            while !Task.isCancelled {
                model.viewport = 190 + CGFloat(step % 20) / 2
                step += 1
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { churn.cancel() }
        let began = ProcessInfo.processInfo.systemUptime, start = driver.interactions.count
        do {
            try await driver.click("reflow.field", in: window)
            Issue.record("A target with changing geometry received input.")
        } catch {
            #expect((error as? GateBlocked)?.message == "The native input target did not settle: reflow.field")
        }
        #expect(ProcessInfo.processInfo.systemUptime - began >= 1)
        let attempt = driver.interactions.dropFirst(start)
        let unsettled = try #require(attempt.last { $0["label"] as? String == "native input target did not settle" })
        #expect(((unsettled["evidence"] as? [String: Any])?["changes"] as? Int ?? 0) > 3)
        #expect(!attempt.contains { $0["kind"] as? String == "pointer" })
    }
}

@MainActor private func nativePointerCGBounds(_ window: NSWindow) -> CGRect? {
    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let matches = rows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
        && ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }
    guard matches.count == 1, let raw = matches[0][kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: raw as CFDictionary)
}

extension NativePointerInteractionTests {
    @MainActor private final class LateReflow {
        var moved: NSRect?
    }

    @Test func aControlMovedAfterThePreDownGuardNeverReceivesTheDown() async throws {
        let fixture = try await Fixture("moved-after-guard")
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.moveAway()
        let window = fixture.window, root = try #require(window.contentView)
        let probe = try #require(fixture.probe("Card"))
        let scroll = try #require(probe.enclosingScrollView)
        let callbacks = fixture.capture.callbacks.count
        let reflow = LateReflow()
        // Reproduces a host reflow that lands after the guard passed and before AppKit dispatches the press.
        do {
            try await fixture.driver.click("pointer.Card", in: window, preDown: {
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + probe.bounds.height * 2))
                scroll.reflectScrolledClipView(clip)
                reflow.moved = probe.convert(probe.bounds, to: root)
                return true
            })
            Issue.record("A control that moved after the pre-Down guard let its old point receive the press.")
        } catch {
            #expect((error as? GateBlocked)?.message == "The verified control moved before AppKit dispatched the Down.")
        }
        let input = try fixture.input("Card")
        let refusal = try #require(input["downTargetRefusal"] as? [String: Any])
        let original = try #require((input["preDownGuard"] as? [String: Any])?["originalTarget"] as? [String: Any])
        let moved = try #require(reflow.moved)
        #expect((refusal["comparisons"] as? [String: Bool])?["probeFrame"] == false)
        #expect(refusal["originalProbeFrame"] as? [CGFloat] == original["probeFrame"] as? [CGFloat])
        #expect(refusal["probeFrame"] as? [CGFloat] == [moved.minX, moved.minY, moved.width, moved.height])
        #expect(input["ownedDownPosted"] as? Bool == true && input["localMonitorDownObserved"] as? Bool == true)
        #expect((input["status"] as? String)?.hasPrefix("failed:") == true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.capture.callbacks.count == callbacks)
        #expect(!CGEventSource.buttonState(.combinedSessionState, button: .left))
        try fixture.record("moved-after-guard", ["input": input, "callbacks": fixture.capture.callbacks])
    }
}

@Suite("Native disclosure discovery", .serialized)
@MainActor
struct NativeDisclosureInteractionTests {
    @MainActor private struct Sections: View {
        @State var camera: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                DisclosureSection("Camera and continuity", probe: "disclosure.camera", isExpanded: $camera) {
                    Text("Blocking").reviewAcceptanceProbe("disclosure.camera.content")
                }
                DisclosureSection("Iteration limits", probe: "disclosure.limits") {
                    Text("Rolls").reviewAcceptanceProbe("disclosure.limits.content")
                }
                .disabled(true)
            }
            .padding(AppTheme.Spacing.xl)
            .environment(\.pipelineAcceptanceProbes, true)
            .frame(width: 420, height: 240, alignment: .topLeading)
        }
    }

    private func probe(_ id: String, in root: NSView) -> AppRelaunchClickProbeView? { WorkspaceUIAcceptance.findProbe(in: root, identifier: id) as? AppRelaunchClickProbeView }

    @Test func sectionStateDrivesItsProbeAndOmitsCollapsedContent() {
        for expanded in [false, true] {
            let host = hosted(Sections(camera: expanded))
            let camera = probe("disclosure.camera", in: host)
            #expect(camera?.acceptanceText == (expanded ? "expanded" : "collapsed") && camera?.acceptanceState == true)
            #expect((probe("disclosure.camera.content", in: host) != nil) == expanded)
            #expect(probe("disclosure.limits", in: host)?.acceptanceState == false)
            #expect(probe("disclosure.limits", in: host)?.acceptanceText == "collapsed" && probe("disclosure.limits.content", in: host) == nil)
        }
    }

    @Test func pointerTogglesTheDisclosureSectionThroughItsProbe() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--no-parallel"))
        let events = try #require(ProcessInfo.processInfo.environment["NGV_APPKIT_TEST_EVENTS"])
        let folder = URL(fileURLWithPath: events).deletingLastPathComponent()
            .appendingPathComponent("native-disclosure-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let application = try await NativePointerApplicationLease.acquire()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Sections(camera: false))
        sheet.contentView = NSHostingView(rootView: Sections(camera: false))
        defer {
            if sheet.sheetParent != nil { window.endSheet(sheet) }
            sheet.contentView = nil; window.contentView = nil
            sheet.close(); window.close(); application.close()
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        let driver = ProductionVisualSourcesDriver(window: window, output: folder, name: "disclosure")
        try await driver.wait("disclosure fixture active") { NSApp.isActive && window.isKeyWindow }
        try await toggleTwice(driver: driver, in: window)
        window.beginSheet(sheet, completionHandler: nil)
        sheet.contentView?.layoutSubtreeIfNeeded()
        try await driver.wait("disclosure sheet active") { sheet.sheetParent === window && sheet.isKeyWindow }
        try await toggleTwice(driver: driver, in: sheet)
    }

    private func hosted(_ sections: Sections) -> NSView {
        let host = NSHostingView(rootView: sections)
        host.setFrameSize(NSSize(width: 420, height: 240))
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func toggleTwice(driver: ProductionVisualSourcesDriver, in target: NSWindow) async throws {
        for expanded in [true, false] {
            let start = driver.interactions.count
            try await ProductionNativeDisclosureAcceptance.toggle("disclosure.camera", content: "disclosure.camera.content",
                expanded: expanded, driver: driver, in: target)
            let state = expanded ? "expanded" : "collapsed"
            #expect(driver.text("disclosure.camera", in: target) == state)
            #expect((driver.state("disclosure.camera.content", in: target) != nil) == expanded)
            let added = driver.interactions.dropFirst(start)
            let pointer = try #require(added.last { $0["kind"] as? String == "pointer" && $0["id"] as? String == "disclosure.camera" })
            #expect(pointer["localMonitorDownObserved"] as? Bool == true && pointer["localMonitorUpObserved"] as? Bool == true)
            let record = try #require(added.last { $0["label"] as? String == "native disclosure pointer" })
            #expect((record["evidence"] as? [String: Any])?["after"] as? String == state)
        }
        let start = driver.interactions.count
        do {
            try await driver.click("disclosure.limits", in: target)
            Issue.record("A disabled disclosure accepted pointer input.")
        } catch {
            #expect((error as? GateBlocked)?.message == "Control is disabled: disclosure.limits")
        }
        #expect(!driver.interactions.dropFirst(start).contains { $0["kind"] as? String == "pointer" })
        #expect(driver.text("disclosure.limits", in: target) == "collapsed")
        #expect(driver.state("disclosure.limits.content", in: target) == nil)
    }
}

extension NativePointerInteractionTests {
    // Replaces the target's view on every scroll step, as a lazy SwiftUI stack may do with a row it re-materializes.
    @MainActor private final class ReplacingTarget {
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 360, height: 1600))
        private(set) var current: AppRelaunchClickProbeView
        private(set) var replacements = 0

        init() {
            current = Self.make()
            document.addSubview(current)
        }

        func replace() {
            let next = Self.make()
            current.removeFromSuperview()
            document.addSubview(next)
            current = next
            replacements += 1
        }

        private static func make() -> AppRelaunchClickProbeView {
            let view = AppRelaunchClickProbeView(frame: NSRect(x: 40, y: 900, width: 160, height: 24))
            view.identifier = NSUserInterfaceItemIdentifier("replaced.target")
            view.acceptanceState = true
            return view
        }
    }

    @MainActor private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private func verifyRevealOfReplacedLazyControls() async throws {
        try await verifyLazyStoryboardMenu()
        try await verifyFirstWheelStepKeepsLazyRows()
        let fixture = try await Fixture("replaced-reveal-target")
        defer { fixture.close() }
        let window = fixture.window, driver = fixture.driver
        let root = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        let scroll = NSScrollView(frame: root.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let target = ReplacingTarget()
        scroll.documentView = target.document
        root.addSubview(scroll)
        window.contentView = root
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                              queue: .main) { _ in MainActor.assumeIsolated { target.replace() } }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await driver.waitForPresentation(of: window, control: "replaced.target")
        let original = target.current
        #expect(!clip.bounds.contains(original.convert(original.bounds, to: clip)))
        let start = driver.interactions.count
        try await driver.reveal("replaced.target", in: window)
        let wheels = driver.interactions.dropFirst(start).filter { $0["kind"] as? String == "wheel" && $0["id"] as? String == "replaced.target" }
        #expect(!wheels.isEmpty)
        #expect(wheels.allSatisfy { $0["controlReplaced"] as? Bool == true })
        #expect(target.replacements >= wheels.count && target.current !== original)
        #expect(clip.bounds.contains(target.current.convert(target.current.bounds, to: clip)))
    }
}

extension NativePointerInteractionTests {
    // Moves 7 pt per posted wheel unit, the rate the signed Board run measured; the first gesture may move faster.
    @MainActor private final class FixedRateScroll: NSScrollView {
        var firstGestureRate: CGFloat = 7
        private(set) var gestures: [Int64] = []
        private var units: Int64 = 0

        override func scrollWheel(with event: NSEvent) {
            let delta = event.cgEvent?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) ?? 0
            units += delta
            let clip = contentView
            if delta != 0, let document = documentView {
                let rate = gestures.isEmpty ? firstGestureRate : 7
                let limit = max(0, document.frame.height - clip.bounds.height)
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(limit, max(0, clip.bounds.minY - CGFloat(delta) * rate))))
                reflectScrolledClipView(clip)
            }
            guard event.phase.contains(.ended) else { return }
            gestures.append(units)
            units = 0
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: self)
        }
    }

    // Keeps its row only within 60 pt of the viewport, as a lazy stack does.
    @MainActor private final class LazyRow {
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 360, height: 1600))
        let frame = NSRect(x: 40, y: 150, width: 160, height: 24)
        private(set) var current: AppRelaunchClickProbeView?
        private(set) var drops = 0

        func update(_ viewport: NSRect) {
            let materialized = frame.intersects(viewport.insetBy(dx: 0, dy: -60))
            if materialized, current == nil {
                let view = AppRelaunchClickProbeView(frame: frame)
                view.identifier = NSUserInterfaceItemIdentifier("lazy.wheel.target")
                view.acceptanceState = true
                document.addSubview(view)
                current = view
            } else if !materialized, let view = current {
                view.removeFromSuperview()
                current = nil
                drops += 1
            }
        }
    }

    private func revealLazyRow(firstGestureRate: CGFloat) async throws -> (wheels: [[String: Any]], row: LazyRow) {
        let fixture = try await Fixture("lazy-wheel-" + String(Int(firstGestureRate)))
        defer { fixture.close() }
        let window = fixture.window, driver = fixture.driver
        let root = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        let scroll = FixedRateScroll(frame: NSRect(x: 0, y: root.bounds.height - 160, width: root.bounds.width, height: 120))
        scroll.firstGestureRate = firstGestureRate
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        let row = LazyRow()
        scroll.documentView = row.document
        root.addSubview(scroll)
        window.contentView = root
        let clip = scroll.contentView
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
        row.update(clip.bounds)
        clip.postsBoundsChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                              queue: .main) { _ in MainActor.assumeIsolated { row.update(clip.bounds) } }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await driver.waitForPresentation(of: window, control: "lazy.wheel.target")
        try #require(clip.bounds.height == 120 && clip.bounds.minY == 0 && row.current != nil)
        let start = driver.interactions.count
        try await driver.reveal("lazy.wheel.target", in: window)
        let shown = try #require(row.current)
        #expect(clip.bounds.contains(shown.convert(shown.bounds, to: clip)))
        let wheels = driver.interactions.dropFirst(start).filter {
            $0["kind"] as? String == "wheel" && $0["id"] as? String == "lazy.wheel.target"
        }
        #expect(scroll.gestures == wheels.compactMap { wheel in (wheel["delta"] as? Int32).map { Int64($0) } })
        return (wheels, row)
    }

    private func verifyFirstWheelStepKeepsLazyRows() async throws {
        let calibrated = try await revealLazyRow(firstGestureRate: 7)
        // An uncalibrated step of 100 units carried this 120 pt viewport 700 pt past the row and dropped it.
        let first = try #require(calibrated.wheels.first?["delta"] as? Int32)
        #expect(first < 0 && abs(first) <= 15)
        #expect(calibrated.row.drops == 0 && !calibrated.wheels.contains { $0["controlLost"] as? Bool == true })

        let overshot = try await revealLazyRow(firstGestureRate: 40)
        #expect(overshot.row.drops >= 1)
        #expect(overshot.wheels.first?["controlLost"] as? Bool == true)
        #expect(overshot.wheels.count >= 2 && overshot.wheels.last?["controlLost"] as? Bool == false)
    }
}
