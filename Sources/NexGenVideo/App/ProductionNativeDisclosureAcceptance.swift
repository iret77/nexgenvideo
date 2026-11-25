import AppKit
import NexGenEngine

@MainActor
enum ProductionNativeDisclosureAcceptance {
    static func toggle(_ id: String, content: String, expanded: Bool,
                       driver: ProductionVisualSourcesDriver, in window: NSWindow) async throws {
        let initial = expanded ? "collapsed" : "expanded", requested = expanded ? "expanded" : "collapsed"
        try await driver.reveal(id, in: window)
        guard driver.text(id, in: window) == initial, (driver.state(content, in: window) != nil) != expanded else {
            throw GateBlocked("The disclosure has an unexpected initial state: " + id)
        }
        try await driver.click(id, in: window)
        try await driver.wait("disclosure " + requested + " " + id) {
            driver.text(id, in: window) == requested && (driver.state(content, in: window) != nil) == expanded
        }
        try driver.record("native disclosure pointer", fields: ["id": id, "content": content, "expanded": expanded,
            "before": initial, "after": requested, "input": "nativePointer"])
    }
}
