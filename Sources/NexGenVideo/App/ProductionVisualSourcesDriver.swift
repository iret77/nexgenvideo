import AppKit
import ApplicationServices
import NexGenEngine
import SwiftUI

@MainActor
final class ProductionVisualSourcesDriver {
    let window: NSWindow
    let output: URL
    let name: String
    private(set) var interactions: [[String: Any]] = []
    private(set) var screenshots: [String] = []
    private(set) var stage = "start"
    private var latestField: [String: Any] = [:]
    private var accessibilityFailure: String?

    init(window: NSWindow, output: URL, name: String) {
        self.window = window; self.output = output; self.name = name
    }

    func wait(_ label: String, seconds: Double = 10, _ ready: () -> Bool) async throws {
        stage = label
        try persist()
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard ready() else { throw GateBlocked("Native visual sources: " + label + "; " + diagnostic()) }
    }

    func text(_ id: String, in target: NSWindow) -> String? { WorkspaceUIAcceptance.probeText(identifier: id, in: target) }
    func state(_ id: String, in target: NSWindow) -> Bool? { WorkspaceUIAcceptance.probeState(identifier: id, in: target) }

    func sheet(_ id: String, parent: NSWindow? = nil) async throws -> NSWindow {
        let parent = parent ?? window
        try await wait("open sheet " + id) {
            guard let sheet = parent.attachedSheet else { return false }
            return sheet.isKeyWindow && self.probe(id, in: sheet) != nil
        }
        guard let result = parent.attachedSheet else { throw GateBlocked("The native sheet disappeared.") }
        return result
    }

    func visible(_ ids: [String], in target: NSWindow) throws {
        guard target.isVisible, target.isKeyWindow, let root = target.contentView else {
            throw GateBlocked("The native window is not active.")
        }
        var frames: [NSRect] = []
        for id in ids {
            guard let view = probe(id, in: target), fullyVisible(view, root: root) else {
                throw GateBlocked("The complete control is clipped or missing: " + id)
            }
            let frame = view.convert(view.bounds, to: root)
            guard frames.allSatisfy({ !$0.intersects(frame) }) else { throw GateBlocked("Native controls overlap: " + id) }
            frames.append(frame)
        }
        interactions.append(["kind": "visible-group", "ids": ids, "window": target.windowNumber,
            "frames": frames.map(rect), "viewport": rect(root.bounds)])
        try persist()
    }

    func reveal(_ id: String, in target: NSWindow) async throws {
        try await wait("locate " + id) { self.probe(id, in: target) != nil }
        guard let root = target.contentView else { throw GateBlocked("The native content view disappeared.") }
        for _ in 0..<45 {
            root.layoutSubtreeIfNeeded()
            guard let view = probe(id, in: target) else { throw GateBlocked("Control disappeared while scrolling: " + id) }
            if fullyVisible(view, root: root) { return }
            var ancestor = view.superview
            var clipping: NSScrollView?
            while let current = ancestor {
                if let scroll = current as? NSScrollView,
                   !scroll.contentView.bounds.contains(view.convert(view.bounds, to: scroll.contentView)) {
                    clipping = scroll; break
                }
                ancestor = current.superview
            }
            guard let scroll = clipping, let screen = NSScreen.screens.first else {
                throw GateBlocked("Control is outside the native window without a scroll path: " + id)
            }
            let clip = scroll.contentView
            let frame = view.convert(view.bounds, to: clip)
            guard frame.height <= clip.bounds.height, frame.width <= clip.bounds.width else {
                throw GateBlocked("Control exceeds its scroll viewport: " + id)
            }
            let below = frame.midY > clip.bounds.midY
            let delta: Int32 = below == clip.isFlipped ? -100 : 100
            let center = NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY)
            guard target.isKeyWindow, let hit = root.hitTest(scroll.convert(center, to: root.superview)),
                  hit === scroll || hit.isDescendant(of: scroll) else { throw GateBlocked("The scroll viewport is covered: " + id) }
            let point = target.convertPoint(toScreen: scroll.convert(center, to: nil))
            let before = clip.bounds.origin
            try await postWheel(delta: delta, at: CGPoint(x: point.x, y: screen.frame.height - point.y), in: target)
            try await wait("native scroll applied " + id, seconds: 2) { clip.bounds.origin != before }
            interactions.append(["kind": "wheel", "id": id, "delta": delta,
                "before": [before.x, before.y], "after": [clip.bounds.origin.x, clip.bounds.origin.y]])
        }
        throw GateBlocked("Wheel input did not reveal the complete control: " + id)
    }

    func postWheel(delta: Int32, at location: CGPoint, in target: NSWindow) async throws {
        guard CGPreflightPostEventAccess() else { throw GateBlocked("Native wheel input needs event-posting permission.") }
        try await ProductionNativeReadingAcceptance.movePointer(to: location, window: target, driver: self)
        for event in try HangDiagnosticReplay.scrollGestureEvents(delta: delta, location: location) {
            guard let input = event.cgEvent else { throw GateBlocked("The native wheel event is unavailable.") }
            input.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    func measureFont(_ id: String, in target: NSWindow, scale: Double) async throws -> Double {
        try await reveal(id, in: target)
        guard let frame = WorkspaceUIAcceptance.probeFrame(identifier: id, in: target), let root = target.contentView else {
            throw GateBlocked("The typography control is unavailable: " + id)
        }
        let fields = views(root).compactMap { view -> (CGFloat?, String)? in
            guard !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty,
                  frame.insetBy(dx: -1, dy: -1).contains(view.convert(view.visibleRect, to: root)) else { return nil }
            if let field = view as? NSTextField, field.isEditable { return (field.font?.pointSize, "text-field") }
            if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { return (text.font?.pointSize, "text-view") }
            return nil
        }
        guard fields.count == 1, let size = fields[0].0,
              abs(size - AppTheme.Typography.ui * scale) < 0.5 else {
            throw GateBlocked("The rendered typography does not match the requested scale: " + id)
        }
        try record("rendered typography", fields: ["id": id, "pointSize": size, "baseSize": AppTheme.Typography.ui, "scale": scale,
            "controlKind": fields[0].1, "window": target.windowNumber])
        return Double(size)
    }

    func click(_ id: String, in target: NSWindow, enabled: Bool = true, fraction: NSPoint = .init(x: 0.5, y: 0.5)) async throws {
        let transaction = try NativeAcceptancePointer.claim()
        defer { NativeAcceptancePointer.release(transaction) }
        try await click(id, in: target, enabled: enabled, fraction: fraction, transaction: transaction)
    }

    private func click(_ id: String, in target: NSWindow, enabled: Bool = true,
                       fraction: NSPoint = .init(x: 0.5, y: 0.5), transaction: UUID) async throws {
        guard [fraction.x, fraction.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw GateBlocked("The native pointer fraction is invalid: " + id)
        }
        stage = "click " + id
        try await reveal(id, in: target)
        try visible([id], in: target)
        guard !enabled || state(id, in: target) == true,
              let frame = WorkspaceUIAcceptance.probeFrame(identifier: id, in: target),
              let root = target.contentView else { throw GateBlocked("Control is disabled: " + id) }
        guard let view = probe(id, in: target) else { throw GateBlocked("The native pointer probe disappeared: " + id) }
        let point = view.convert(NSPoint(x: view.bounds.minX + view.bounds.width * fraction.x,
                                        y: view.bounds.minY + view.bounds.height * fraction.y), to: root)
        let hit = root.hitTest(root.convert(point, to: root.superview))
        let windowPoint = root.convert(point, to: nil)
        guard hit != nil else {
            throw GateBlocked("The actual pointer target is unavailable: " + id)
        }
        let index = interactions.count
        interactions.append(["kind": "pointer", "id": id, "window": target.windowNumber,
            "frame": rect(frame), "point": [point.x, point.y], "hitClass": String(describing: type(of: hit!)),
            "windowPoint": [windowPoint.x, windowPoint.y]])
        do {
            try await NativeAcceptancePointer.click(view, window: target, fraction: fraction, token: transaction) { evidence in
                self.interactions[index]["nativeInput"] = evidence
                self.interactions[index]["localMonitorEvents"] = (evidence["received"] as? [[String: Any]])?.filter {
                    [NSEvent.EventType.leftMouseDown.rawValue, NSEvent.EventType.leftMouseUp.rawValue].contains($0["type"] as? UInt ?? 0)
                }
                self.interactions[index]["localMonitorDownObserved"] = evidence["localMonitorDownObserved"]
                self.interactions[index]["localMonitorUpObserved"] = evidence["localMonitorUpObserved"]
                try self.persist()
            }
        } catch {
            if interactions[index]["nativeInput"] == nil {
                interactions[index]["nativeInput"] = ["status": "refused: " + String(describing: error),
                    "posted": [], "received": [], "ownedDownPosted": false, "ownedUpPosted": false]
            }
            try persist()
            throw error
        }
        try persist()
    }

    func clickButton(_ id: String, title: String, in target: NSWindow) async throws {
        let transaction = try NativeAcceptancePointer.claim()
        defer { NativeAcceptancePointer.release(transaction) }
        try await reveal(id, in: target)
        var match: (frames: [NSRect], evidence: [String: Any]) = ([], [:])
        stage = "actual enabled button " + title
        try persist()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        do {
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                match = await buttonFrames(id, title: title, in: target)
                if state(id, in: target) == true && match.frames.count == 1 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard state(id, in: target) == true && match.frames.count == 1 else {
                throw GateBlocked("Native visual sources: actual enabled button " + title + "; " + diagnostic())
            }
        } catch {
            interactions.append(match.evidence)
            try persist()
            throw error
        }
        match = await buttonFrames(id, title: title, in: target)
        try Task.checkCancellation()
        interactions.append(match.evidence)
        try persist()
        guard match.frames.count == 1, let frame = match.frames.first, let view = probe(id, in: target) else {
            throw GateBlocked("The actual button has no unique enabled accessibility frame: " + title)
        }
        let fraction = NSPoint(x: (frame.midX - view.bounds.minX) / view.bounds.width,
                               y: (frame.midY - view.bounds.minY) / view.bounds.height)
        let before = interactions.count
        try await click(id, in: target, fraction: fraction, transaction: transaction)
        let pointer = interactions.dropFirst(before).last { ($0["kind"] as? String) == "pointer" && ($0["id"] as? String) == id }
        let native = pointer?["nativeInput"] as? [String: Any]
        guard pointer?["localMonitorDownObserved"] as? Bool == true,
              native?["buttonDownObserved"] as? Bool == true,
              native?["buttonReleased"] as? Bool == true else {
            throw GateBlocked("The actual button lacks a verified native pointer lifecycle: " + title)
        }
    }

    private func buttonFrames(_ id: String, title: String, in target: NSWindow) async -> (frames: [NSRect], evidence: [String: Any]) {
        var evidence: [String: Any] = ["kind": "button-accessibility", "id": id, "item": title, "window": target.windowNumber]
        guard target.isKeyWindow, let root = target.contentView, let view = probe(id, in: target),
              view.window === target, fullyVisible(view, root: root), let screen = NSScreen.screens.first else { return ([], evidence) }
        let windowFrame = target.frame
        let publicWindow = NSRect(x: windowFrame.minX, y: screen.frame.maxY - windowFrame.maxY,
                                  width: windowFrame.width, height: windowFrame.height)
        let contentScreen = target.convertToScreen(root.convert(root.bounds, to: nil))
        let publicContent = NSRect(x: contentScreen.minX, y: screen.frame.maxY - contentScreen.maxY,
                                   width: contentScreen.width, height: contentScreen.height)
        let request = NativeButtonAccessibility.Request(pid: getpid(), windowNumber: target.windowNumber,
            windowFrame: .init(publicWindow), contentFrame: .init(publicContent))
        let snapshot: NativeButtonAccessibility.Snapshot
        do {
            let result = try await NativeAXPeer.withSession { session in
                await NativeButtonAccessibility.read(request, using: session)
            }
            snapshot = result.0
            evidence["readerLifecycle"] = result.1.evidence
        } catch {
            evidence["readerFailure"] = String(describing: error)
            return ([], evidence)
        }
        evidence["publicAX"] = snapshot.evidence
        evidence["visited"] = snapshot.nodes.count
        evidence["truncated"] = !snapshot.complete
        guard target.isKeyWindow, target.frame == windowFrame, target.contentView === root,
              target.convertToScreen(root.convert(root.bounds, to: nil)) == contentScreen, view.window === target,
              probe(id, in: target) === view, fullyVisible(view, root: root) else { return ([], evidence) }
        let probeScreen = target.convertToScreen(view.convert(view.bounds, to: nil))
        let publicProbe = NSRect(x: probeScreen.minX, y: screen.frame.maxY - probeScreen.maxY,
                                 width: probeScreen.width, height: probeScreen.height)
        let nodes = NativeButtonAccessibility.buttons(snapshot, title: title, inside: .init(publicProbe))
        var frames: [NSRect] = [], observed: [[String: Any]] = []
        for node in nodes {
            guard let frame = node.frame else { continue }
            let screenFrame = NSRect(x: frame.x, y: screen.frame.maxY - frame.y - frame.height,
                                     width: frame.width, height: frame.height)
            let local = view.convert(target.convertFromScreen(screenFrame), from: nil)
            let within = view.bounds.insetBy(dx: -1, dy: -1).contains(local)
                && view.bounds.contains(NSPoint(x: local.midX, y: local.midY))
            var item = node.evidence
            item["screenFrame"] = rect(screenFrame)
            item["frameInProbe"] = rect(local)
            item["withinProbe"] = within
            observed.append(item)
            if within { frames.append(local) }
        }
        evidence["elements"] = observed
        evidence["probeBounds"] = rect(view.bounds)
        return (snapshot.complete ? frames : [], evidence)
    }

    func drag(_ id: String, from start: NSPoint, to end: NSPoint, in target: NSWindow) async throws {
        try await reveal(id, in: target)
        try visible([id], in: target)
        guard target.isKeyWindow, state(id, in: target) == true,
              let view = probe(id, in: target), let root = target.contentView else {
            throw GateBlocked("The drag control is unavailable: " + id)
        }
        for fraction in [start, end] {
            guard (0...1).contains(fraction.x), (0...1).contains(fraction.y),
                  root.hitTest(view.convert(NSPoint(x: view.bounds.minX + fraction.x * view.bounds.width,
                                                    y: view.bounds.minY + fraction.y * view.bounds.height), to: root.superview)) != nil else {
                throw GateBlocked("The native drag endpoint is outside its control: " + id)
            }
        }
        for step in 0...9 {
            let fraction = CGFloat(min(step, 8)) / 8
            let point = NSPoint(x: start.x + (end.x - start.x) * fraction,
                                y: start.y + (end.y - start.y) * fraction)
            let location = view.convert(NSPoint(x: view.bounds.minX + point.x * view.bounds.width,
                                                y: view.bounds.minY + point.y * view.bounds.height), to: nil)
            let type: NSEvent.EventType = step == 0 ? .leftMouseDown : step == 9 ? .leftMouseUp : .leftMouseDragged
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, eventNumber: step, clickCount: 1, pressure: step == 9 ? 0 : 1) else {
                throw GateBlocked("Could not create a native drag event.")
            }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(30))
        }
        interactions.append(["kind": "drag", "id": id, "window": target.windowNumber,
            "start": [start.x, start.y], "end": [end.x, end.y]])
        try persist()
    }

    func modifiedClick(_ id: String, modifiers: NSEvent.ModifierFlags, in target: NSWindow) async throws {
        try await reveal(id, in: target)
        try visible([id], in: target)
        guard state(id, in: target) == true, let view = probe(id, in: target), let root = target.contentView else {
            throw GateBlocked("The modified pointer control is unavailable: " + id)
        }
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard root.hitTest(root.convert(root.convert(location, from: nil), to: root.superview)) != nil else { throw GateBlocked("The pointer is outside the window.") }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { throw GateBlocked("The pointer event could not be created.") }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(30))
        }
        interactions.append(["kind": "modified-pointer", "id": id, "modifiers": modifiers.rawValue,
                             "command": modifiers.contains(.command), "shift": modifiers.contains(.shift)])
        try persist()
    }

    func dragBetween(_ id: String, sourcePoint: NSPoint? = nil, destination: NSView,
                     point: NSPoint, label: String, in target: NSWindow) async throws {
        try await reveal(id, in: target)
        guard target.isKeyWindow, destination.window === target, let source = probe(id, in: target),
              let root = target.contentView, !destination.isHiddenOrHasHiddenAncestor else {
            throw GateBlocked("The native drag source or destination is unavailable.")
        }
        let localStart = sourcePoint ?? NSPoint(x: source.bounds.midX, y: source.bounds.midY)
        guard source.bounds.contains(localStart), destination.visibleRect.contains(point) else {
            throw GateBlocked("The native drag endpoints are clipped.")
        }
        let start = source.convert(localStart, to: nil), end = destination.convert(point, to: nil)
        for endpoint in [start, end] {
            let location = root.convert(endpoint, from: nil)
            guard root.bounds.contains(location), root.hitTest(root.convert(location, to: root.superview)) != nil else { throw GateBlocked("The drag endpoint cannot receive pointer input.") }
        }
        for step in 0...13 {
            let fraction = CGFloat(min(step, 12)) / 12
            let location = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            let type: NSEvent.EventType = step == 0 ? .leftMouseDown : step == 13 ? .leftMouseUp : .leftMouseDragged
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                eventNumber: step, clickCount: 1, pressure: step == 13 ? 0 : 1) else { throw GateBlocked("The drag event could not be created.") }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(30))
        }
        interactions.append(["kind": "cross-view-drag", "id": id, "destination": label,
            "sourcePoint": [start.x, start.y], "destinationPoint": [end.x, end.y], "queuedEvents": 14])
        try persist()
    }

    func fill(_ id: String, value: String, in target: NSWindow, requireFocusExit: Bool = false,
              commitByClicking: String? = nil) async throws {
        try await click(id, in: target)
        var owner: NSView?
        var editor: NSTextView?
        func ownership() -> Bool {
            guard let owner, let editor, target.firstResponder === editor, editor.isEditable else { return false }
            if let field = owner as? NSTextField { return field.currentEditor() === editor }
            return owner === editor
        }
        func evidence(_ step: String) {
            let font = (owner as? NSTextField)?.font ?? (owner as? NSTextView)?.font
            latestField = ["id": id, "stage": step, "expected": value, "actual": text(id, in: target) ?? "<missing>",
                "editorText": editor?.string ?? "<missing>", "owner": owner.map { String(describing: type(of: $0)) } ?? "none",
                "ownsEditor": ownership(), "window": target.windowNumber,
                "fontPointSize": font?.pointSize as Any? ?? NSNull(),
                "firstResponder": target.firstResponder.map { String(describing: type(of: $0)) } ?? "none"]
        }
        try await wait("focus exact field " + id) {
            guard let frame = WorkspaceUIAcceptance.probeFrame(identifier: id, in: target), let root = target.contentView,
                  let first = target.firstResponder as? NSTextView else { evidence("focus"); return false }
            let candidates = self.views(root).filter { view in
                let editable = (view as? NSTextField)?.isEditable == true || ((view as? NSTextView)?.isEditable == true && view === first && !(first.isFieldEditor))
                let bounds = view.convert(view.bounds, to: root)
                return editable && !view.isHiddenOrHasHiddenAncestor && frame.insetBy(dx: -1, dy: -1).contains(bounds)
                    && bounds.contains(NSPoint(x: frame.midX, y: frame.midY))
            }
            if candidates.count == 1 { owner = candidates[0]; editor = first }
            evidence("focus")
            let font = (owner as? NSTextField)?.font ?? (owner as? NSTextView)?.font
            let scale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
            return ownership() && font.map { abs($0.pointSize - AppTheme.Typography.ui * scale) < 0.5 } == true
        }
        try key(0, "a", modifiers: .command, in: target)
        try await wait("select all " + id) {
            evidence("select-all")
            return ownership() && editor?.selectedRange() == NSRange(location: 0, length: (editor!.string as NSString).length)
        }
        try key(51, "\u{7f}", in: target)
        try await wait("clear " + id) { evidence("clear"); return ownership() && editor?.string == "" }
        for character in value { try key(0, String(character), in: target) }
        try await wait("type " + id) { evidence("type"); return ownership() && editor?.string == value }
        if let commitByClicking {
            try await click(commitByClicking, in: target, enabled: false)
        } else {
            try key(48, "\t", in: target)
        }
        try await wait("field value after commit input " + id) {
            evidence("commit-requested")
            return self.text(id, in: target) == value && (!ownership() || (!requireFocusExit && editor?.string == value))
        }
        latestField["commitInput"] = commitByClicking.map { "Pointer:" + $0 } ?? "Tab"
        latestField["requiresFocusExit"] = requireFocusExit
        latestField["focusLeftTarget"] = !ownership()
        interactions.append(["kind": "text", "field": latestField])
        try persist()
    }

    func menu(_ id: String, title: String, in target: NSWindow) async throws {
        try await selectMenu(id, path: [title], context: false, in: target)
    }

    func menu(_ id: String, path: [String], in target: NSWindow) async throws {
        try await selectMenu(id, path: path, context: false, in: target)
    }

    func contextMenu(_ id: String, path: [String], in target: NSWindow) async throws {
        try await selectMenu(id, path: path, context: true, in: target)
    }

    func contextMenu(path: [String], in target: NSWindow, open: @escaping () throws -> Void) async throws {
        try await selectMenu("timeline.context", path: path, context: true, in: target, open: open)
    }

    private func selectMenu(_ id: String, path: [String], context: Bool, in target: NSWindow,
                            open: (() throws -> Void)? = nil) async throws {
        guard !path.isEmpty else { throw GateBlocked("A native menu choice needs an item.") }
        @MainActor final class Tracking {
            var titles: [[String]] = []
            var closed = false
            var error: String?
            var root: NSMenu?
            var expectedSubmenu: NSMenu?
        }
        let tracking = Tracking()
        let begin = NativeOwnerMenuObserver(name: NSMenu.didBeginTrackingNotification) { menu in
            guard tracking.root == nil || menu === tracking.expectedSubmenu else { return }
            if tracking.root == nil { tracking.root = menu }
            let depth = tracking.titles.count
            guard depth < path.count else { return }
            let title = path[depth]
            tracking.titles.append(menu.items.map(\.title))
            let selectable = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.isEnabled }
            guard let index = selectable.firstIndex(where: { $0.title == title }) else {
                tracking.error = "The native menu does not contain an enabled item: " + title
                try? self.key(53, "\u{1b}", in: target); return
            }
            do {
                try self.key(115, "\u{f729}", in: target)
                for _ in 0..<index { try self.key(125, "\u{f701}", in: target) }
                if depth + 1 < path.count {
                    guard let submenu = selectable[index].submenu else {
                        throw GateBlocked("The native menu has no submenu: " + title)
                    }
                    tracking.expectedSubmenu = submenu
                    try self.key(124, "\u{f703}", in: target)
                } else { try self.key(36, "\r", in: target) }
            } catch { tracking.error = error.localizedDescription }
        }
        let end = NativeOwnerMenuObserver(name: NSMenu.didEndTrackingNotification) { menu in
            if menu === tracking.root { tracking.closed = true }
        }
        defer { NotificationCenter.default.removeObserver(begin); NotificationCenter.default.removeObserver(end) }
        if let open { try open() }
        else if context {
            try await reveal(id, in: target)
            try visible([id], in: target)
            guard target.isKeyWindow, let view = probe(id, in: target) else { throw GateBlocked("No native context-menu target.") }
            let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0) else {
                    throw GateBlocked("Could not create the native context-menu pointer event.")
                }
                NSApp.postEvent(event, atStart: false)
            }
        } else { try await click(id, in: target) }
        try await wait("native menu " + path.joined(separator: " / ")) { tracking.closed || tracking.error != nil }
        if let error = tracking.error { tracking.root?.cancelTracking(); throw GateBlocked(error) }
        guard tracking.titles.count == path.count else { throw GateBlocked("The complete native menu path was not observed.") }
        interactions.append(["kind": context ? "context-menu" : "menu", "id": id,
            "item": path.last!, "path": path, "titles": tracking.titles.first ?? [], "menus": tracking.titles, "closed": tracking.closed])
        try persist()
    }

    func picker(_ id: String, title: String, expected: String, in target: NSWindow) async throws {
        try await menu(id, title: title, in: target)
        try await wait("picker binding " + id) { self.text(id, in: target) == expected }
    }

    func segment(_ id: String, title: String, titles: [String], expected: String? = nil, in target: NSWindow) async throws {
        try await reveal(id, in: target)
        try visible([id], in: target)
        guard let segmentIndex = titles.firstIndex(of: title), let view = probe(id, in: target), let root = target.contentView else {
            throw GateBlocked("The native segmented control is unavailable: " + id)
        }
        let frame = view.convert(view.bounds, to: root)
        let controls = views(root).compactMap { $0 as? NSSegmentedControl }.filter { control in
            !control.isHiddenOrHasHiddenAncestor && frame.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: root))
                && control.segmentCount == titles.count
                && (0..<control.segmentCount).map { control.label(forSegment: $0) } == titles.map(Optional.some)
        }
        guard controls.count == 1, let control = controls.first, control.isEnabled, control.isEnabled(forSegment: segmentIndex) else {
            throw GateBlocked("The actual segmented control does not match its visible labels: " + id)
        }
        var pending: [any NSAccessibilityProtocol] = [control]
        var visited = Set<ObjectIdentifier>()
        var matches: [NSRect] = []
        var observed: [[String: Any]] = []
        while let element = pending.popLast(), visited.count < 64 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let label = element.accessibilityLabel() ?? "", itemTitle = element.accessibilityTitle() ?? ""
            let screenFrame = element.accessibilityFrame()
            let enabled = element.isAccessibilityEnabled()
            let geometry = segmentInteractionGeometry(screenFrame, control: control, segmentIndex: segmentIndex, probe: view, in: target)
            var observation = geometry.evidence
            observation["label"] = label
            observation["title"] = itemTitle
            observation["accessibilityEnabled"] = enabled
            observed.append(observation)
            if ObjectIdentifier(element) != ObjectIdentifier(control), [label, itemTitle].contains(title),
               screenFrame.width > 0 && screenFrame.height > 0 && enabled,
               let candidate = geometry.frame, !matches.contains(candidate) { matches.append(candidate) }
            pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        interactions.append(["kind": "segment-accessibility", "id": id, "item": title, "elements": observed])
        try persist()
        guard matches.count == 1, let selected = matches.first else {
            throw GateBlocked("The actual segment has no unique visible accessibility frame: " + title)
        }
        let fraction = NSPoint(x: (selected.midX - view.bounds.minX) / view.bounds.width,
                               y: (selected.midY - view.bounds.minY) / view.bounds.height)
        guard state(id, in: target) == true, fullyVisible(control, root: root),
              let hit = root.hitTest(root.convert(view.convert(NSPoint(x: selected.midX, y: selected.midY), to: root), to: root.superview)),
              hit === control || hit.isDescendant(of: control),
              WorkspaceUIAcceptance.click(identifier: id, in: target, fraction: fraction) == nil else {
            throw GateBlocked("The actual segment cannot receive pointer input: " + title)
        }
        let point = view.convert(NSPoint(x: selected.midX, y: selected.midY), to: root)
        interactions.append(["kind": "pointer", "id": id, "window": target.windowNumber,
            "frame": rect(frame), "point": [point.x, point.y], "hitClass": String(describing: type(of: hit))])
        try persist()
        try await wait("native segment selected " + title) {
            control.selectedSegment == segmentIndex && self.text(id, in: target) == (expected ?? title)
        }
    }

    func segmentInteractionGeometry(_ screenFrame: NSRect, control: NSSegmentedControl, segmentIndex: Int,
                                    probe: NSView, in target: NSWindow) -> (frame: NSRect?, evidence: [String: Any]) {
        var evidence: [String: Any] = ["screenFrame": rect(screenFrame).map { $0.isFinite ? $0 as Any : String(describing: $0) }, "probeBounds": rect(probe.bounds),
            "controlBounds": rect(control.bounds), "controlVisibleRect": rect(control.visibleRect),
            "controlFrameInProbe": rect(control.convert(control.bounds, to: probe)), "controlEnabled": control.isEnabled]
        func rejected(_ reason: String) -> (frame: NSRect?, evidence: [String: Any]) {
            evidence["rejection"] = reason
            return (nil, evidence)
        }
        guard control.window === target, probe.window === target, let root = target.contentView else {
            return rejected("different-window")
        }
        guard (0..<control.segmentCount).contains(segmentIndex) else { return rejected("invalid-segment") }
        evidence["segmentEnabled"] = control.isEnabled(forSegment: segmentIndex)
        guard control.isEnabled, control.isEnabled(forSegment: segmentIndex) else { return rejected("disabled-control-or-segment") }
        guard [screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height].allSatisfy(\.isFinite),
              screenFrame.width > 0, screenFrame.height > 0 else { return rejected("invalid-accessibility-frame") }
        let native = control.convert(target.convertFromScreen(screenFrame), from: nil)
        // AX frames include native decoration beyond the control's pointer bounds.
        let interaction = native.intersection(control.bounds)
        evidence["nativeAccessibilityFrame"] = rect(native)
        evidence["localFrame"] = rect(probe.convert(native, from: control))
        guard !interaction.isNull, interaction.width > 0, interaction.height > 0 else { return rejected("no-native-intersection") }
        let local = probe.convert(interaction, from: control)
        evidence["nativeInteractionFrame"] = rect(interaction)
        evidence["interactionFrame"] = rect(local)
        guard fullyVisible(control, root: root), control.visibleRect.contains(control.bounds) else {
            return rejected("clipped-or-hidden-native-control")
        }
        guard control.bounds.contains(NSPoint(x: native.midX, y: native.midY)) else { return rejected("accessibility-center-outside-control") }
        guard control.visibleRect.contains(interaction), probe.bounds.contains(local) else { return rejected("interaction-outside-probe") }
        let hit = root.hitTest(control.convert(NSPoint(x: interaction.midX, y: interaction.midY), to: root.superview))
        evidence["hitClass"] = hit.map { String(describing: type(of: $0)) } ?? "none"
        guard let hit, hit === control || hit.isDescendant(of: control) else { return rejected("covered-pointer-target") }
        evidence["rejection"] = ""
        return (local, evidence)
    }

    func chooseFile(_ url: URL?, in sheet: NSWindow, trigger: String? = "storyboard.native-sketch.choose", returnsToParent: Bool = true) async throws {
        if let trigger { try await click(trigger, in: sheet) }
        try await wait("native file panel") { NSApp.windows.contains { ($0 as? NSOpenPanel)?.isVisible == true } }
        guard let panel = NSApp.windows.compactMap({ $0 as? NSOpenPanel }).first(where: \.isVisible) else {
            throw GateBlocked("No actual NSOpenPanel appeared.")
        }
        try capture("file-panel", target: panel)
        guard let url else {
            try key(53, "\u{1b}", in: panel)
            try await wait("cancel native file panel") { !panel.isVisible && sheet.isKeyWindow }
            interactions.append(["kind": "file-panel-cancel"]); try persist(); return
        }
        try key(5, "G", modifiers: [.command, .shift], in: panel)
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 1)
        var focused: AXUIElement?
        var localEditor: NSTextView?
        func recordPath(_ stage: String) {
            latestField = ["id": "native-open-panel.path", "stage": stage, "expected": url.path,
                "actual": localEditor?.string ?? focused.flatMap { self.axValue($0, kAXValueAttribute) as? String } ?? "<missing>",
                "selectedURL": panel.url?.path ?? "<none>", "panel": panel.windowNumber,
                "firstResponder": String(describing: NSApp.keyWindow?.firstResponder)]
        }
        try await wait("Go to Folder text editor") {
            recordPath("focus")
            if let current = NSApp.keyWindow, current === panel || current.sheetParent === panel,
               let editor = current.firstResponder as? NSTextView, editor.isEditable {
                localEditor = editor; return true
            }
            guard let element = self.axElement(app, kAXFocusedUIElementAttribute),
                  let role = self.axValue(element, kAXRoleAttribute) as? String,
                  [kAXTextFieldRole, kAXComboBoxRole].contains(role) else { return false }
            focused = element; return true
        }
        let inputWindow = NSApp.keyWindow ?? panel
        try key(0, "a", modifiers: .command, in: inputWindow)
        for character in url.path { try key(0, String(character), in: inputWindow) }
        try await wait("file path typed in native editor") {
            recordPath("typed")
            if let localEditor { return inputWindow.firstResponder === localEditor && localEditor.string == url.path }
            guard let focused else { return false }
            return self.axValue(focused, kAXValueAttribute) as? String == url.path
        }
        try key(36, "\r", in: inputWindow)
        try await wait("native file selected") { recordPath("selected"); return panel.url?.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() }
        try capture("file-selected", target: panel)
        try key(36, "\r", in: panel)
        try await wait("native file selection accepted") { !panel.isVisible && (!returnsToParent || sheet.isKeyWindow) }
        interactions.append(["kind": "file-panel", "path": url.lastPathComponent, "selectedURLVerified": true,
            "nativePathEditorVerified": true])
        try persist()
    }

    func inspect(_ id: String, in parent: NSWindow) async throws {
        try await click(id, in: parent)
        let sheet = try await sheet("production.image-inspection.image", parent: parent)
        try visible(["production.image-inspection.image", "production.image-inspection.close"], in: sheet)
        try capture("inspect", target: sheet)
        try await click("production.image-inspection.close", in: sheet)
        try await wait("close image inspection") { parent.attachedSheet == nil && parent.isKeyWindow }
    }

    func saveFile(_ destination: URL, in parent: NSWindow, returnsToParent: Bool = true) async throws {
        try await wait("native save panel") { NSApp.windows.contains { $0 is NSSavePanel && !($0 is NSOpenPanel) && $0.isVisible } }
        let panels = NSApp.windows.compactMap { $0 as? NSSavePanel }.filter { !($0 is NSOpenPanel) && $0.isVisible }
        guard parent.isVisible, panels.count == 1, let panel = panels.first,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw GateBlocked("The native save panel or its unused output destination is unavailable.")
        }
        try await wait("save panel keyboard focus") { panel.isKeyWindow }
        try capture("save-panel", target: panel)
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 1)
        let previousEditor = panel.firstResponder as? NSTextView
        let previousDelegate = previousEditor?.delegate as AnyObject?
        let previousFocus = axElement(app, kAXFocusedUIElementAttribute)
        try key(5, "G", modifiers: [.command, .shift], in: panel)
        var folderEditor: NSTextView?
        var focused: AXUIElement?
        try await wait("save panel folder editor") {
            if let current = NSApp.keyWindow, current === panel || current.sheetParent === panel,
               let editor = current.firstResponder as? NSTextView, editor.isEditable,
               editor !== previousEditor || (editor.delegate as AnyObject?) !== previousDelegate {
                folderEditor = editor; return true
            }
            guard let element = self.axElement(app, kAXFocusedUIElementAttribute),
                  previousFocus.map({ !CFEqual($0, element) }) ?? true,
                  let role = self.axValue(element, kAXRoleAttribute) as? String,
                  [kAXTextFieldRole, kAXComboBoxRole].contains(role) else { return false }
            focused = element; return true
        }
        let input = NSApp.keyWindow ?? panel, directory = destination.deletingLastPathComponent()
        try key(0, "a", modifiers: .command, in: input)
        try key(51, "\u{7f}", in: input)
        for character in directory.path { try key(0, String(character), in: input) }
        try await wait("save directory typed") {
            let actual = folderEditor?.string ?? focused.flatMap { self.axValue($0, kAXValueAttribute) as? String }
            self.latestField = ["id": "native-save-panel.directory", "expected": directory.path, "actual": actual ?? "<missing>"]
            return actual == directory.path
        }
        try key(36, "\r", in: input)
        try await wait("save directory selected") { panel.isKeyWindow && panel.directoryURL?.standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath() }
        let oldName = panel.nameFieldStringValue
        guard !oldName.isEmpty else { throw GateBlocked("The save panel has no identifiable output name field.") }
        let candidates = panel.contentView.map(views)?.compactMap { $0 as? NSTextField }.filter {
            $0.isEditable && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == oldName
        } ?? []
        if candidates.count == 1, let field = candidates.first, let root = panel.contentView {
            guard fullyVisible(field, root: root) else { throw GateBlocked("The output filename field is clipped.") }
            try nativePointer(field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil), in: panel)
            try await wait("output filename field owns keyboard") {
                guard let editor = panel.firstResponder as? NSTextView else { return false }
                return field.currentEditor() === editor && editor.isEditable
            }
        } else {
            var pending = [app], visited: [AXUIElement] = [], matches: [NSRect] = []
            while let element = pending.popLast(), visited.count < 512 {
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                if axValue(element, kAXRoleAttribute) as? String == kAXTextFieldRole,
                   axValue(element, kAXValueAttribute) as? String == oldName,
                   axValue(element, kAXEnabledAttribute) as? Bool == true,
                   let position = axValue(element, kAXPositionAttribute), let size = axValue(element, kAXSizeAttribute),
                   CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                    var point = CGPoint.zero, dimensions = CGSize.zero
                    if AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
                       let screen = NSScreen.screens.first {
                        let screenFrame = NSRect(x: point.x, y: screen.frame.height - point.y - dimensions.height,
                                                 width: dimensions.width, height: dimensions.height)
                        if panel.frame.contains(screenFrame), dimensions.width > 0, dimensions.height > 0 { matches.append(screenFrame) }
                    }
                }
                pending += axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
            guard matches.count == 1, let frame = matches.first else {
                throw GateBlocked("The native output name has no unique visible text field.")
            }
            try nativePointer(panel.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)), in: panel)
            try await wait("accessible output filename owns keyboard") {
                guard let field = self.axElement(app, kAXFocusedUIElementAttribute) else { return false }
                return self.axValue(field, kAXRoleAttribute) as? String == kAXTextFieldRole
                    && self.axValue(field, kAXValueAttribute) as? String == oldName
            }
        }
        try key(0, "a", modifiers: .command, in: panel)
        try key(51, "\u{7f}", in: panel)
        for character in destination.lastPathComponent { try key(0, String(character), in: panel) }
        try key(48, "\t", in: panel)
        try await wait("exact output filename committed") {
            self.latestField = ["id": "native-save-panel.filename", "expected": destination.lastPathComponent,
                "actual": panel.nameFieldStringValue, "url": panel.url?.path ?? "<missing>"]
            return panel.nameFieldStringValue == destination.lastPathComponent
                && panel.url?.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath()
        }
        try capture("save-selected", target: panel)
        try key(36, "\r", in: panel)
        try await wait("native save accepted") { !panel.isVisible && (!returnsToParent || parent.isKeyWindow) }
        interactions.append(["kind": "save-panel", "filename": destination.lastPathComponent,
            "nativeDirectoryAndFilenameTyped": true, "exactURLVerified": true])
        try persist()
    }

    private func nativePointer(_ point: NSPoint, in window: NSWindow) throws {
        guard window.isVisible, window.isKeyWindow, let root = window.contentView,
              root.bounds.contains(root.convert(point, from: nil)), root.hitTest(root.convert(root.convert(point, from: nil), to: root.superview)) != nil else {
            throw GateBlocked("The native pointer location has no visible hit target.")
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw GateBlocked("The native pointer event could not be created.")
            }
            NSApp.postEvent(event, atStart: false)
        }
        interactions.append(["kind": "native-pointer", "window": window.windowNumber, "point": [point.x, point.y]])
        try persist()
    }

    func capture(_ label: String, target: NSWindow) throws {
        guard let content = target.contentView else { throw GateBlocked("No native window image is available.") }
        content.layoutSubtreeIfNeeded(); target.displayIfNeeded()
        let filename = name + "-" + String(screenshots.count) + "-" + label + ".png"
        guard WorkspaceUIAcceptance.snapshot(content, at: output.appendingPathComponent(filename)) else {
            throw GateBlocked("Could not capture the actual native window: " + label)
        }
        screenshots.append(filename); try persist()
    }

    func failure(_ error: Error) {
        for target in NSApp.windows.filter(\.isVisible) { try? capture("failed-window-\(target.windowNumber)", target: target) }
        try? persist(failure: error.localizedDescription)
    }

    func result() -> [String: Any] { ["interactions": interactions, "screenshots": screenshots, "progress": name + ".json"] }

    func pressKey(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], in target: NSWindow) throws {
        guard target.isKeyWindow else { throw GateBlocked("The keyboard target is not the active native window.") }
        interactions.append(["kind": "keyboard", "code": code, "characters": characters,
            "modifiers": modifiers.rawValue, "window": target.windowNumber,
            "firstResponder": String(describing: target.firstResponder)])
        try persist()
        try key(code, characters, modifiers: modifiers, in: target)
    }

    func record(_ label: String, fields: [String: Any]) throws {
        stage = label
        interactions.append(["kind": "verified-state", "label": label, "evidence": fields])
        try persist()
    }

    private func persist(failure: String? = nil) throws {
        let value: [String: Any] = ["schema": "native-visual-source-progress/v1", "stage": stage,
            "interactions": interactions, "screenshots": screenshots, "latestField": latestField,
            "diagnostic": diagnostic(), "failure": failure as Any? ?? NSNull()]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name + ".json"), options: .atomic)
    }

    private func diagnostic() -> String {
        "key=\(NSApp.keyWindow?.windowNumber ?? -1), responder=\(String(describing: NSApp.keyWindow?.firstResponder)), field=\(latestField), accessibility=\(accessibilityFailure ?? "available")"
    }

    private func probe(_ id: String, in target: NSWindow) -> NSView? {
        guard let root = target.contentView else { return nil }
        return WorkspaceUIAcceptance.findProbe(in: root, identifier: id)
    }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func rect(_ value: NSRect) -> [Double] { [value.minX, value.minY, value.width, value.height].map(Double.init) }
    private func fullyVisible(_ view: NSView, root: NSView) -> Bool {
        let frame = view.convert(view.bounds, to: root)
        guard !view.isHiddenOrHasHiddenAncestor, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, root.bounds.contains(frame) else { return false }
        var ancestor = view.superview
        while let parent = ancestor {
            if let clip = parent as? NSClipView, !clip.bounds.contains(view.convert(view.bounds, to: clip)) { return false }
            ancestor = parent.superview
        }
        return root.hitTest(root.convert(NSPoint(x: frame.midX, y: frame.midY), to: root.superview)) != nil
    }
    private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { accessibilityFailure = "\(attribute): \(result.rawValue)"; return nil }
        accessibilityFailure = nil
        return value
    }
    private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = axValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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

@MainActor
private protocol NativeAcceptanceHostingSurface: AnyObject {
    func accessibilityHitTest(_ point: NSPoint) -> Any?
}

extension NSHostingView: NativeAcceptanceHostingSurface {}

final class NativePointerPoster: @unchecked Sendable {
    private let source: CGEventSource
    private let down: CGEvent
    private let up: CGEvent
    private let point: CGPoint
    private let window: Int
    private let tag: Int64
    private let windowBounds: CGRect
    private let deliver: @Sendable (CGEvent) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var downSeen = false
    private var state: [String: Any] = ["posted": [[String: Any]](), "ownedDownPosted": false,
        "ownedUpPosted": false, "buttonDownObserved": false, "buttonReleased": true, "cleanupUpPosted": false]
    private let screenPoint: NSPoint

    init(source: CGEventSource, down: CGEvent, up: CGEvent, point: CGPoint, window: Int,
         windowBounds: CGRect, screenPoint: NSPoint, tag: Int64,
         deliver: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.source = source; self.down = down; self.up = up; self.point = point; self.window = window; self.tag = tag
        self.windowBounds = windowBounds; self.deliver = deliver
        self.screenPoint = screenPoint
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func observedDown() { lock.lock(); downSeen = true; lock.unlock() }
    func snapshot() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return state }

    private func stopped() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func observed() -> Bool { lock.lock(); defer { lock.unlock() }; return downSeen }
    private func put(_ key: String, _ value: Any) { lock.lock(); state[key] = value; lock.unlock() }

    private func post(_ event: CGEvent, type: CGEventType, cleanup: Bool = false) {
        lock.lock()
        var events = state["posted"] as! [[String: Any]]
        events.append(["type": type.rawValue, "point": [point.x, point.y], "tag": tag,
                       "postedUptime": ProcessInfo.processInfo.systemUptime, "cleanup": cleanup])
        state["posted"] = events
        state[type == .leftMouseDown ? "ownedDownPosted" : "ownedUpPosted"] = true
        if cleanup { state["cleanupUpPosted"] = true }
        lock.unlock()
        deliver(event)
    }

    private func awaitRelease() {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while CGEventSource.buttonState(.combinedSessionState, button: .left)
                && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.002) }
    }

    func run() async {
        let screenPoint = screenPoint
        let hitWindow = await MainActor.run {
            NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        }
        postSequence(hitWindow: hitWindow)
    }

    private func postSequence(hitWindow: Int) {
        put("hitWindowBeforeDown", hitWindow)
        guard hitWindow == window, !stopped(), !CGEventSource.buttonState(.combinedSessionState, button: .left),
              let actual = CGEvent(source: nil)?.location,
              abs(actual.x - point.x) < 0.5, abs(actual.y - point.y) < 0.5 else {
            put("error", "The system pointer or button changed before Down.")
            put("buttonReleased", !CGEventSource.buttonState(.combinedSessionState, button: .left))
            return
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let matches = windows.filter { value in
            (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
                && (value[kCGWindowNumber as String] as? NSNumber)?.intValue == window
        }
        guard matches.count == 1, let top = matches.first,
              let rawBounds = top[kCGWindowBounds as String] as? [String: Any],
              CGRect(dictionaryRepresentation: rawBounds as CFDictionary) == windowBounds else {
            put("error", "The original native window changed before Down.")
            return
        }
        post(down, type: .leftMouseDown)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !observed() && !stopped() && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        let downObserved = observed() && CGEventSource.buttonState(.combinedSessionState, button: .left)
        put("buttonDownObserved", downObserved)
        if !downObserved { put("error", "Tagged local Down and OS Down were not both observed.") }
        let releaseAt = ProcessInfo.processInfo.systemUptime + 0.03
        while !stopped() && ProcessInfo.processInfo.systemUptime < releaseAt { Thread.sleep(forTimeInterval: 0.002) }
        post(up, type: .leftMouseUp)
        awaitRelease()
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            put("error", "The original Up did not release the OS button.")
            post(up, type: .leftMouseUp, cleanup: true)
            awaitRelease()
        }
        let released = !CGEventSource.buttonState(.combinedSessionState, button: .left)
        put("buttonReleased", released)
        if !released { put("error", "Owned Up cleanup could not release the OS button.") }
        withExtendedLifetime(source) {}
    }
}

@MainActor
enum NativeAcceptancePointer {
    static func claim() throws -> UUID {
        if let cleanupFailure { throw GateBlocked(cleanupFailure) }
        guard owner == nil else { throw GateBlocked("A native pointer transaction is already active.") }
        let token = UUID()
        owner = token
        return token
    }

    static func release(_ token: UUID) {
        if owner == token { owner = nil }
    }

    private struct Target {
        let window: NSWindow
        let root: NSView
        let probe: NSView
        let hit: NSView
        let windowFrame: NSRect
        let probeFrame: NSRect
        let point: NSPoint
        let screenPoint: NSPoint
        let quartzPoint: CGPoint
        let cgFrame: CGRect
        let accessibility: AnyObject
        let accessibilityRole: NSAccessibility.Role
        let accessibilityFrame: NSRect
        let kind: String
    }

    private static func target(_ probe: NSView, window: NSWindow, fraction: NSPoint) throws -> Target {
        guard NSApp.isActive, window.isVisible, window.isKeyWindow, !window.ignoresMouseEvents,
              let root = window.contentView, probe.window === window,
              !probe.isHiddenOrHasHiddenAncestor,
              [fraction.x, fraction.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let screen = NSScreen.screens.first else {
            throw GateBlocked("The original native pointer target is unavailable.")
        }
        let frame = probe.convert(probe.bounds, to: root)
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0, root.bounds.contains(frame) else {
            throw GateBlocked("The native pointer target has no complete finite frame.")
        }
        var parent = probe.superview
        while let view = parent {
            if let clip = view as? NSClipView,
               !clip.bounds.contains(probe.convert(probe.bounds, to: clip)) {
                throw GateBlocked("The native pointer target is clipped.")
            }
            parent = view.superview
        }
        let local = NSPoint(x: probe.bounds.minX + probe.bounds.width * fraction.x,
                            y: probe.bounds.minY + probe.bounds.height * fraction.y)
        let point = probe.convert(local, to: nil)
        guard let hit = root.hitTest(probe.convert(local, to: root.superview)) else {
            throw GateBlocked("The native pointer target cannot receive input.")
        }
        let appKitPoint = window.convertPoint(toScreen: point)
        let quartzPoint = CGPoint(x: appKitPoint.x, y: screen.frame.maxY - appKitPoint.y)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let matches = windows.filter { item in
            (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
                && (item[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber
        }
        guard NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: 0) == window.windowNumber,
              matches.count == 1, let covering = matches.first,
              let rawBounds = covering[kCGWindowBounds as String] as? [String: Any],
              let cgFrame = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
              [cgFrame.minX, cgFrame.minY, cgFrame.width, cgFrame.height].allSatisfy(\.isFinite),
              cgFrame.width > 0, cgFrame.height > 0, cgFrame.contains(quartzPoint) else {
            throw GateBlocked("The original native window is covered at the pointer target.")
        }
        let accessible: AnyObject
        let role: NSAccessibility.Role
        let accessibleFrame: NSRect
        let kind: String
        if let surface = hit as? any NativeAcceptanceHostingSurface, probe.isDescendant(of: hit) {
            guard let leaf = surface.accessibilityHitTest(appKitPoint) as? any NSAccessibilityProtocol else {
                throw GateBlocked("The SwiftUI pointer target has no known accessibility hit.")
            }
            var element: (any NSAccessibilityProtocol)? = leaf
            var control: (AnyObject, NSAccessibility.Role, NSRect)?
            var visited = Set<ObjectIdentifier>()
            var originalWindow = false
            let roles: Set<String> = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXTextFieldRole,
                kAXTextAreaRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXMenuItemRole, kAXComboBoxRole,
                kAXSliderRole, kAXDisclosureTriangleRole, kAXIncrementorRole, kAXColorWellRole]
            let surfaces: Set<String> = [kAXGroupRole, kAXStaticTextRole, kAXImageRole, kAXScrollAreaRole,
                kAXSplitGroupRole, kAXListRole, kAXRowRole, kAXCellRole, kAXTableRole, kAXColumnRole,
                kAXOutlineRole, kAXToolbarRole, kAXHeadingRole, kAXTabGroupRole, kAXRadioGroupRole,
                kAXLayoutAreaRole, kAXLayoutItemRole, kAXValueIndicatorRole, kAXSplitterRole]
            for _ in 0..<32 {
                guard let current = element, visited.insert(ObjectIdentifier(current)).inserted else { break }
                if let actualWindow = current as? NSWindow {
                    originalWindow = actualWindow === window
                    break
                }
                guard let currentRole = current.accessibilityRole(),
                      roles.contains(currentRole.rawValue) || surfaces.contains(currentRole.rawValue) else {
                    throw GateBlocked("The pointer accessibility ancestry has an unknown role.")
                }
                if roles.contains(currentRole.rawValue) {
                    let bounds = current.accessibilityFrame()
                    guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
                          bounds.width > 0, bounds.height > 0, bounds.contains(appKitPoint),
                          current.isAccessibilityEnabled() else {
                        throw GateBlocked("The actual pointer control is disabled or has changed geometry.")
                    }
                    if control == nil { control = (current, currentRole, bounds) }
                }
                element = current.accessibilityParent() as? any NSAccessibilityProtocol
            }
            guard originalWindow else { throw GateBlocked("The pointer accessibility ancestry does not prove the original window.") }
            if let control {
                (accessible, role, accessibleFrame) = control
                kind = "accessibility-control"
            } else {
                guard let leafRole = leaf.accessibilityRole() else { throw GateBlocked("The gesture target has no known role.") }
                accessible = leaf
                role = leafRole
                accessibleFrame = leaf.accessibilityFrame()
                guard [accessibleFrame.minX, accessibleFrame.minY, accessibleFrame.width, accessibleFrame.height].allSatisfy(\.isFinite),
                      accessibleFrame.width > 0, accessibleFrame.height > 0, accessibleFrame.contains(appKitPoint) else {
                    throw GateBlocked("The gesture accessibility target has no finite visible frame.")
                }
                kind = "gesture-surface"
            }
        } else {
            let bounds = hit.convert(hit.bounds, to: root)
            guard (hit is NSControl || hit is NSTextView),
                  !hit.isHiddenOrHasHiddenAncestor, !hit.visibleRect.isEmpty,
                  frame.insetBy(dx: -1, dy: -1).contains(bounds),
                  hit.visibleRect.contains(hit.convert(point, from: nil)),
                  hit.isAccessibilityEnabled(), let nativeRole = hit.accessibilityRole(),
                  !nativeRole.rawValue.isEmpty, nativeRole.rawValue != kAXUnknownRole else {
                throw GateBlocked("A disabled or different native view covers the pointer control.")
            }
            accessible = hit
            role = nativeRole
            accessibleFrame = hit.accessibilityFrame()
            kind = "native-control"
        }
        return Target(window: window, root: root, probe: probe, hit: hit, windowFrame: window.frame,
                      probeFrame: frame, point: point, screenPoint: appKitPoint, quartzPoint: quartzPoint, cgFrame: cgFrame,
                      accessibility: accessible, accessibilityRole: role, accessibilityFrame: accessibleFrame, kind: kind)
    }

    private static func same(_ first: Target, _ next: Target) -> Bool {
        first.window === next.window && first.root === next.root && first.probe === next.probe
            && first.hit === next.hit && first.windowFrame == next.windowFrame
            && first.probeFrame == next.probeFrame && first.point == next.point
            && first.cgFrame == next.cgFrame
            && first.accessibility === next.accessibility && first.accessibilityRole == next.accessibilityRole
            && first.accessibilityFrame == next.accessibilityFrame && first.kind == next.kind
    }

    private static func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
        }
    }

    static func click(_ probe: NSView, window: NSWindow, fraction: NSPoint,
                      token: UUID, record: ([String: Any]) throws -> Void) async throws {
        guard owner == token, CGPreflightPostEventAccess(),
              !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            throw GateBlocked("Native pointer input is unavailable or a mouse button is already held.")
        }
        let original = try target(probe, window: window, fraction: fraction)
        let tag = Int64.random(in: 1...Int64.max)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: original.quartzPoint, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: original.quartzPoint, mouseButton: .left) else {
            throw GateBlocked("The complete native pointer sequence could not be created.")
        }
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        @MainActor final class Delivery {
            var events: [[String: Any]] = []
            var down = false
            var up = false
            var moves: [NSPoint] = []
        }
        let poster = NativePointerPoster(source: source, down: down, up: up, point: original.quartzPoint,
                                         window: window.windowNumber, windowBounds: original.cgFrame,
                                         screenPoint: original.screenPoint, tag: tag)
        let delivery = Delivery(), number = window.windowNumber, point = original.point
        let acceptedMoves = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp]) { event in
            let observedTag = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            let location = event.locationInWindow, observedWindow = event.windowNumber, type = event.type
            let pressed = CGEventSource.buttonState(.combinedSessionState, button: .left)
            let global = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard observedTag == tag else { return }
                let root = original.root
                let local = root.convert(location, from: nil)
                let hit = root.hitTest(root.convert(local, to: root.superview))
                delivery.events.append(["type": type.rawValue, "window": observedWindow,
                    "point": [location.x, location.y], "screenPoint": [global.x, global.y],
                    "tag": tag, "buttonDown": pressed, "observedUptime": ProcessInfo.processInfo.systemUptime,
                    "hitClass": hit.map { String(describing: Swift.type(of: $0)) } ?? "none"])
                if type == .mouseMoved && observedWindow == number { delivery.moves.append(location) }
                guard observedWindow == number, abs(location.x - point.x) < 0.5,
                      abs(location.y - point.y) < 0.5 else { return }
                if type == .leftMouseDown && pressed {
                    delivery.down = true
                    poster.observedDown()
                }
                if type == .leftMouseUp && !pressed { delivery.up = true }
            }
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            window.acceptsMouseMovedEvents = acceptedMoves
        }
        var posted: [[String: Any]] = []
        func emit(_ event: CGEvent, type: CGEventType) {
            event.post(tap: .cghidEventTap)
            posted.append(["type": type.rawValue, "point": [event.location.x, event.location.y],
                           "tag": tag, "postedUptime": ProcessInfo.processInfo.systemUptime])
        }
        func evidence(_ status: String) -> [String: Any] {
            var value = poster.snapshot()
            value.merge(["kind": "native-pointer", "transaction": token.uuidString, "tag": tag, "status": status,
                "window": number, "point": [point.x, point.y],
                "screenPoint": [original.screenPoint.x, original.screenPoint.y], "targetKind": original.kind,
                "accessibilityRole": original.accessibilityRole.rawValue,
                "accessibilityFrame": [original.accessibilityFrame.minX, original.accessibilityFrame.minY,
                                       original.accessibilityFrame.width, original.accessibilityFrame.height],
                "posted": posted + (value["posted"] as? [[String: Any]] ?? []), "received": delivery.events,
                "localMonitorDownObserved": delivery.down, "localMonitorUpObserved": delivery.up,
                "upDeliveryAcknowledged": false]) { _, new in new }
            return value
        }

        func wait(_ predicate: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                await pause()
            }
            try Task.checkCancellation()
            guard predicate() else { throw GateBlocked("The native pointer event was not observed at its original target.") }
        }
        do {
            try Task.checkCancellation()
            let current = NSEvent.mouseLocation
            var positions: [CGPoint] = []
            if abs(current.x - original.screenPoint.x) < 0.5 && abs(current.y - original.screenPoint.y) < 0.5 {
                let delta: CGFloat = original.point.x + 2 < window.contentView!.bounds.maxX ? 2 : -2
                positions.append(CGPoint(x: original.quartzPoint.x + delta, y: original.quartzPoint.y))
            }
            positions.append(original.quartzPoint)
            for position in positions {
                guard same(original, try target(probe, window: window, fraction: fraction)),
                      let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                         mouseCursorPosition: position, mouseButton: .left) else {
                    throw GateBlocked("The original native pointer target changed before movement.")
                }
                move.setIntegerValueField(.eventSourceUserData, value: tag)
                let expected = window.convertPoint(fromScreen: NSPoint(x: position.x,
                    y: original.screenPoint.y - (position.y - original.quartzPoint.y)))
                let before = delivery.moves.count
                emit(move, type: .mouseMoved)
                try await wait {
                    delivery.moves.dropFirst(before).contains { abs($0.x - expected.x) < 0.5 && abs($0.y - expected.y) < 0.5 }
                }
            }
            let actual = NSEvent.mouseLocation
            guard abs(actual.x - original.screenPoint.x) < 0.5,
                  abs(actual.y - original.screenPoint.y) < 0.5,
                  !CGEventSource.buttonState(.combinedSessionState, button: .left),
                  same(original, try target(probe, window: window, fraction: fraction)) else {
                throw GateBlocked("The actual system pointer or original control changed before Down.")
            }
            try record(evidence("prepared"))
            try Task.checkCancellation()
            let worker = Task.detached { await poster.run() }
            await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                poster.cancel()
            }
            let state = poster.snapshot()
            if state["ownedDownPosted"] as? Bool == true && state["buttonReleased"] as? Bool != true {
                cleanupFailure = "The owned native mouse button could not be released."
                throw GateBlocked(cleanupFailure!)
            }
            try Task.checkCancellation()
            guard state["buttonDownObserved"] as? Bool == true,
                  state["buttonReleased"] as? Bool == true,
                  state["error"] == nil, delivery.down else {
                throw GateBlocked("The native pointer transaction lacks a verified OS button lifecycle.")
            }
            try record(evidence("delivered"))
        } catch {
            try record(evidence("failed: " + String(describing: error)))
            throw error
        }
    }

    private static var owner: UUID?
    private static var cleanupFailure: String?
}
