import AppKit
import ApplicationServices
import UniformTypeIdentifiers

struct GateBlocked: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class PanelProbeDelegate: NSObject, NSApplicationDelegate {
    private let directory: URL
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private var panel: NSOpenPanel?
    private var timer: Timer?
    private var arm = 0
    private var postedAt: TimeInterval?
    private var samples: [[String: Any]] = []
    private var completed = false
    private var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override init() {
        directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PANEL_PROBE_EVIDENCE"]!, isDirectory: true)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let button = NSButton(title: "Show file panel", target: self, action: #selector(open(_:)))
        button.setAccessibilityIdentifier("show-fixture-panel")
        window.contentView = button
        window.title = "Native panel focus fixture"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func open(_ sender: NSButton) {
        guard panel == nil, arm < 2 else { return }
        arm += 1
        completed = false
        let current = NSOpenPanel()
        current.canChooseDirectories = false
        current.canChooseFiles = true
        current.allowsMultipleSelection = false
        current.allowedContentTypes = [.plainText]
        current.prompt = "Choose"
        self.panel = current
        let timer = Timer(timeInterval: 0.15, target: self, selector: #selector(observe), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = current.runModal()
        timer.invalidate()
        self.timer = nil
        let expected = directory.appendingPathComponent("ordinary-file.txt").standardizedFileURL.resolvingSymlinksInPath()
        write(["accepted": response == .OK, "cancelled": response == .cancel,
               "exactFile": response == .OK && current.urls.count == 1
                    && current.urls[0].standardizedFileURL.resolvingSymlinksInPath() == expected],
              "response-\(arm).json")
        self.panel = nil
    }

    @objc private func observe() {
        guard !completed, let panel else { return }
        if arm == 2 {
            guard exists("sample-control") else { return }
            completed = true
            write(snapshot(panel), "control-host.json")
            return
        }
        if postedAt == nil {
            guard exists("observe-local"), panel.isVisible, panel.isKeyWindow, NSApp.modalWindow === panel else { return }
            do {
                let baseline = snapshot(panel)
                try sendOriginalShortcut(in: panel)
                postedAt = clock
                write(["uptime": clock, "baseline": baseline], "local-posted.json")
            } catch {
                completed = true
                write(["error": error.localizedDescription], "local-error.json")
            }
            return
        }
        samples.append(snapshot(panel))
        if let postedAt, clock - postedAt >= 10 {
            completed = true
            write(["samples": samples, "elapsed": clock - postedAt], "local-host.json")
        }
    }

    private func snapshot(_ panel: NSOpenPanel) -> [String: Any] {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 1)
        var focused: CFTypeRef?, role: CFTypeRef?, identifier: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        var roleStatus: AXError?, idStatus: AXError?
        if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = focused as! AXUIElement
            roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            idStatus = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)
        }
        let axRole = role as? String ?? "", key = NSApp.keyWindow
        let local = (key === panel || key?.sheetParent === panel) && (key?.firstResponder as? NSTextView)?.isEditable == true
        return ["uptime": clock, "keyPanel": key === panel, "keyChildOfPanel": key?.sheetParent === panel,
                "modalPanel": NSApp.modalWindow === panel, "localEditor": local, "selfAXRole": axRole,
                "selfAXIsPathField": identifier as? String == "PathTextField", "focusStatus": focusStatus.rawValue,
                "roleStatus": roleStatus?.rawValue as Any? ?? NSNull(), "idStatus": idStatus?.rawValue as Any? ?? NSNull(),
                "m76FocusPredicate": local || [kAXTextFieldRole, kAXComboBoxRole].contains(axRole),
                "accessibilityTrusted": AXIsProcessTrusted(), "panelTree": panelTree(panel)]
    }

    private func panelTree(_ panel: NSOpenPanel) -> [String: Any] {
        func read(_ item: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard item.responds(to: selector) else { return nil }
            return item.perform(selector)?.takeUnretainedValue()
        }
        var pending: [(NSObject, Bool)] = [(panel, false)]
        if let sheet = panel.attachedSheet, sheet.sheetParent === panel { pending.append((sheet, false)) }
        var outside = Set<ObjectIdentifier>(), inside = Set<ObjectIdentifier>()
        var sheets = Set<ObjectIdentifier>(), paths = Set<ObjectIdentifier>(), nestedPaths = Set<ObjectIdentifier>()
        var pathRoles = Set<String>(), sheetRoles = Set<String>()
        let deadline = clock + 0.5
        while !pending.isEmpty, outside.count + inside.count < 1024, clock < deadline {
            let (item, nested) = pending.removeLast(), object = ObjectIdentifier(item)
            if nested { guard inside.insert(object).inserted else { continue } }
            else { guard outside.insert(object).inserted else { continue } }
            let id = read(item, "accessibilityIdentifier") as? String
            if id == "GoToWindow" { sheets.insert(object); sheetRoles.insert(read(item, "accessibilityRole") as? String ?? "") }
            if id == "PathTextField" {
                paths.insert(object); pathRoles.insert(read(item, "accessibilityRole") as? String ?? "")
                if nested { nestedPaths.insert(object) }
            }
            for child in read(item, "accessibilityChildren") as? [NSObject] ?? [] {
                pending.append((child, nested || id == "GoToWindow"))
            }
        }
        return ["sheets": sheets.count, "paths": paths.count, "pathsInSheet": nestedPaths.count,
                "sheetRoles": sheetRoles.sorted(), "pathRoles": pathRoles.sorted(),
                "visited": inside.count + outside.count, "complete": pending.isEmpty]
    }

    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }

    private func write(_ value: [String: Any], _ name: String) {
        do { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: directory.appendingPathComponent(name), options: .atomic) }
        catch { fatalError("Cannot record \(name): \(error)") }
    }
}

@main
struct PanelProbeApp {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = PanelProbeDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
