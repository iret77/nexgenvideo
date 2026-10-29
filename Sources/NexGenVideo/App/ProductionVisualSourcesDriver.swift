import AppKit
import ApplicationServices
import NexGenEngine

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
        let fields = views(root).compactMap { $0 as? NSTextField }.filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.isEditable
                && frame.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: root))
        }
        guard fields.count == 1, let size = fields[0].font?.pointSize,
              abs(size - AppTheme.Typography.ui * scale) < 0.5 else {
            throw GateBlocked("The rendered typography does not match the requested scale: " + id)
        }
        try record("rendered typography", fields: ["id": id, "pointSize": size, "baseSize": AppTheme.Typography.ui, "scale": scale])
        return Double(size)
    }

    func click(_ id: String, in target: NSWindow, enabled: Bool = true, fraction: NSPoint = .init(x: 0.5, y: 0.5)) async throws {
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
        guard hit != nil, WorkspaceUIAcceptance.click(identifier: id, in: target, fraction: fraction) == nil else {
            throw GateBlocked("The actual pointer target is unavailable: " + id)
        }
        interactions.append(["kind": "pointer", "id": id, "window": target.windowNumber,
            "frame": rect(frame), "point": [point.x, point.y], "hitClass": String(describing: type(of: hit!))])
        try persist()
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

    func fill(_ id: String, value: String, in target: NSWindow, requireFocusExit: Bool = false) async throws {
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
        try key(48, "\t", in: target)
        try await wait("field value after commit input " + id) {
            evidence("commit-requested")
            return self.text(id, in: target) == value && (!ownership() || (!requireFocusExit && editor?.string == value))
        }
        latestField["commitInput"] = "Tab"
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

    func contextMenu(path: [String], in target: NSWindow, open: () throws -> Void) async throws {
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
        let begin = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
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
        }
        let end = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated { if menu === tracking.root { tracking.closed = true } }
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

    func segment(_ id: String, title: String, titles: [String], in target: NSWindow) async throws {
        try await reveal(id, in: target)
        try visible([id], in: target)
        guard titles.contains(title), let view = probe(id, in: target), let root = target.contentView else {
            throw GateBlocked("The native segmented control is unavailable: " + id)
        }
        let frame = view.convert(view.bounds, to: root)
        let controls = views(root).compactMap { $0 as? NSSegmentedControl }.filter { control in
            !control.isHiddenOrHasHiddenAncestor && frame.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: root))
                && control.segmentCount == titles.count
                && (0..<control.segmentCount).map { control.label(forSegment: $0) } == titles.map(Optional.some)
        }
        guard controls.count == 1, let control = controls.first, control.isEnabled else {
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
            observed.append(["label": label, "title": itemTitle, "screenFrame": rect(screenFrame)])
            if ObjectIdentifier(element) != ObjectIdentifier(control), [label, itemTitle].contains(title),
               screenFrame.width > 0 && screenFrame.height > 0 && element.isAccessibilityEnabled() {
                let local = view.convert(target.convertFromScreen(screenFrame), from: nil)
                if view.bounds.contains(local), !matches.contains(local) { matches.append(local) }
            }
            pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        interactions.append(["kind": "segment-accessibility", "id": id, "item": title, "elements": observed])
        try persist()
        guard matches.count == 1, let selected = matches.first else {
            throw GateBlocked("The actual segment has no unique visible accessibility frame: " + title)
        }
        let fraction = NSPoint(x: (selected.midX - view.bounds.minX) / view.bounds.width,
                               y: (selected.midY - view.bounds.minY) / view.bounds.height)
        try await click(id, in: target, fraction: fraction)
        try await wait("native segment selected " + title) { self.text(id, in: target) == title }
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
