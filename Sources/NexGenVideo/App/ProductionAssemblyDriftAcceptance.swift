import AppKit
import NexGenEngine

@MainActor
enum ProductionAssemblyDriftAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver) async throws {
        let editor = context.editor, window = driver.window, root = context.dataRoot
        let original = editor.timeline
        let gates = try await Task.detached { try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile)) }.value
        guard let clip = original.tracks.flatMap(\.clips).first(where: { $0.mediaType == .video }), clip.opacity == 1 else {
            throw failed("The assembled production cut has no unchanged video clip for the native drift edit.")
        }
        try await driver.click("editor.workspace.edit", in: window, enabled: false)
        try await driver.wait("native edit workspace for drift") { editor.workspaceFocus == .edit }
        try GenericNLEAcceptance.pointerOnClip(clip, editor: editor, window: window, driver: driver)
        try await driver.wait("production clip selected") { editor.selectedClipIds == [clip.id] }
        try await driver.click("editor.workspace.postproduction", in: window, enabled: false)
        try await driver.wait("native production opacity editor") { editor.workspaceFocus == .postproduction }
        try await driver.fill("inspector.value.Opacity", value: "50", in: window, requireFocusExit: true)
        try await driver.wait("actual production cut edited") {
            editor.timeline.tracks.flatMap(\.clips).first(where: { $0.id == clip.id })?.opacity == 0.5
        }
        let changed = editor.timeline
        try await ProductionV2PlanningAcceptance.selectPhase("render", context: context, driver: driver)
        try await driver.wait("production cut reports drift", seconds: 30) { driver.text("production.assembly.state", in: window) == "drifted" }
        try await driver.reveal("production.assembly.keep", in: window)
        try driver.visible(["production.assembly.keep", "production.assembly.rebuild"], in: window)
        try driver.capture("assembly-drift", target: window)
        try await driver.click("production.assembly.keep", in: window)
        try await driver.wait("Keep opens the actual edited cut") { editor.workspaceFocus == .edit }
        guard editor.timeline == changed,
              try await Task.detached(operation: { try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile)) }).value == gates else {
            throw failed("Keeping the current cut changed its edits or phase approvals.")
        }
        try await ProductionV2PlanningAcceptance.selectPhase("render", context: context, driver: driver)
        try await driver.wait("kept cut still needs explicit rebuild", seconds: 30) { driver.text("production.assembly.state", in: window) == "drifted" }
        try await driver.click("production.assembly.rebuild", in: window)
        let canceled = try await confirmation(driver: driver)
        try driver.visible(["production.assembly.cancel-rebuild", "production.assembly.confirm-rebuild"], in: canceled)
        try driver.capture("assembly-rebuild-confirmation", target: canceled)
        try await driver.click("production.assembly.cancel-rebuild", in: canceled)
        try await driver.wait("native rebuild canceled") {
            window.isKeyWindow && WorkspaceUIAcceptance.probeFrame(identifier: "production.assembly.confirm-rebuild", in: canceled) == nil
        }
        guard editor.timeline == changed else { throw failed("Canceling the rebuild replaced the edited cut.") }
        try await driver.click("production.assembly.rebuild", in: window)
        let confirmed = try await confirmation(driver: driver)
        try await driver.click("production.assembly.confirm-rebuild", in: confirmed)
        try await driver.wait("explicit native rebuild finished", seconds: 90) {
            window.isKeyWindow && driver.text("production.assembly.state", in: window) == "assembled"
        }
        let proof = try await Task.detached {
            try PlanningWriterIO.read(ProductionPlanAssemblyProofV1.self, at: ProductionPlanAssemblyProofV1.relativePath, dataRoot: root)
        }.value
        let placementIDs = Set(proof.placements.map(\.clipID))
        let restoredClips = editor.timeline.tracks.flatMap(\.clips).filter { placementIDs.contains($0.id) }
        guard editor.timeline != changed, placementIDs.count == proof.placements.count,
              restoredClips.count == placementIDs.count, restoredClips.allSatisfy({ $0.opacity == 1 }),
              try await Task.detached(operation: { try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile)) }).value == gates else {
            throw failed("The rebuilt cut retained the changed production opacity or changed approvals.")
        }
        try driver.capture("assembly-rebuilt", target: window)
        try driver.record("native assembly drift keep cancel rebuild", fields: ["editedClipID": clip.id,
            "editedOpacity": 0.5, "keepPreservedTimeline": true, "cancelPreservedTimeline": true,
            "rebuildRestoredPlan": true, "gatesUnchanged": true, "rebuiltClipIDs": proof.placements.map(\.clipID)])
    }

    private static func confirmation(driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        var target: NSWindow?
        try await driver.wait("actual rebuild confirmation") {
            target = NSApp.windows.first { $0.isVisible && $0.isKeyWindow
                && WorkspaceUIAcceptance.probeFrame(identifier: "production.assembly.confirm-rebuild", in: $0) != nil }
            return target != nil
        }
        guard let target else { throw failed("The actual rebuild confirmation disappeared.") }
        return target
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native assembly drift: " + message) }
}
