import AppKit
import Testing

@testable import NexGenVideo

@MainActor
@Suite("Project window presentation", .serialized)
struct ProjectWindowPresentationTests {
    @Test("new project construction keeps Home until the editor becomes key")
    func newProjectWaitsForKeyWindow() throws {
        let home = resetToHome()
        let project = VideoProject()
        NSDocumentController.shared.addDocument(project)
        defer { cleanUp([project]) }

        project.makeWindowControllers()

        #expect(home.isVisible)
        #expect(AppState.shared.activeProject == nil)

        let controller = try #require(
            project.windowControllers.first as? EditorWindowController
        )
        controller.window?.orderFront(nil)
        controller.windowDidBecomeKey(keyNotification(for: controller))

        #expect(AppState.shared.activeProject === project)
        #expect(!home.isVisible)
    }

    @Test("open success registers the document before editor activation")
    func openSuccessRequiresRegistrationBeforeActivation() throws {
        let home = resetToHome()
        let fixture = editorFixture()
        defer { cleanUp([fixture.project]) }

        fixture.controller.showWindow(nil)
        fixture.controller.windowDidBecomeKey(keyNotification(for: fixture.controller))

        #expect(AppState.shared.activeProject == nil)
        #expect(home.isVisible)

        NSDocumentController.shared.addDocument(fixture.project)
        fixture.controller.windowDidBecomeKey(keyNotification(for: fixture.controller))

        #expect(AppState.shared.activeProject === fixture.project)
        #expect(!home.isVisible)
    }

    @Test("cancelled new project leaves Home visible")
    func cancelledNewProjectLeavesHomeVisible() {
        let home = resetToHome()

        AppState.shared.hideHomeIfEditorIsVisible()

        #expect(AppState.shared.activeProject == nil)
        #expect(home.isVisible)
    }

    @Test("failed validation cannot activate an unregistered editor")
    func validationFailureLeavesHomeVisible() {
        let home = resetToHome()
        let fixture = editorFixture()
        defer { cleanUp([fixture.project]) }

        fixture.controller.showWindow(nil)
        fixture.controller.windowDidBecomeKey(keyNotification(for: fixture.controller))

        #expect(AppState.shared.activeProject == nil)
        #expect(home.isVisible)
    }

    @Test("rapid opens select only the editor whose key event arrives")
    func rapidSuccessiveOpensFollowKeyEventOrder() {
        let home = resetToHome()
        let first = editorFixture()
        let second = editorFixture()
        register([first.project, second.project])
        defer { cleanUp([first.project, second.project]) }
        first.controller.showWindow(nil)
        second.controller.showWindow(nil)

        second.controller.windowDidBecomeKey(keyNotification(for: second.controller))

        #expect(AppState.shared.activeProject === second.project)
        #expect(!home.isVisible)
    }

    @Test("switching key editor switches the active project")
    func keyWindowSwitchesActiveProject() {
        _ = resetToHome()
        let first = editorFixture()
        let second = editorFixture()
        register([first.project, second.project])
        defer { cleanUp([first.project, second.project]) }
        first.controller.showWindow(nil)
        second.controller.showWindow(nil)

        first.controller.windowDidBecomeKey(keyNotification(for: first.controller))
        #expect(AppState.shared.activeProject === first.project)

        second.controller.windowDidBecomeKey(keyNotification(for: second.controller))
        #expect(AppState.shared.activeProject === second.project)

        first.controller.windowDidBecomeKey(keyNotification(for: first.controller))
        #expect(AppState.shared.activeProject === first.project)
    }

    @Test("returning Home and reopening an editor repeats the key-window gate")
    func reopeningEditorWaitsForKeyWindowAgain() {
        let home = resetToHome()
        let fixture = editorFixture()
        register([fixture.project])
        defer { cleanUp([fixture.project]) }
        fixture.controller.showWindow(nil)
        fixture.controller.windowDidBecomeKey(keyNotification(for: fixture.controller))
        #expect(!home.isVisible)

        AppState.shared.showHome(persist: false)
        #expect(home.isVisible)
        #expect(AppState.shared.activeProject == nil)

        AppState.shared.showEditor(for: fixture.project)
        #expect(home.isVisible)
        #expect(AppState.shared.activeProject == nil)

        fixture.controller.windowDidBecomeKey(keyNotification(for: fixture.controller))
        #expect(AppState.shared.activeProject === fixture.project)
        #expect(!home.isVisible)
    }

    @Test("notification reveal waits for its editor key event")
    func notificationDrivenOpenWaitsForKeyWindow() {
        let home = resetToHome()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-\(UUID().uuidString).ngv")
        let fixture = editorFixture(fileURL: url)
        register([fixture.project])
        defer { cleanUp([fixture.project]) }

        AppState.shared.revealGeneratedAssetFromNotification(
            assetId: nil,
            projectURL: url
        )

        #expect(fixture.window.isVisible)
        #expect(home.isVisible)
        #expect(AppState.shared.activeProject == nil)

        fixture.controller.windowDidBecomeKey(keyNotification(for: fixture.controller))

        #expect(AppState.shared.activeProject === fixture.project)
        #expect(!home.isVisible)
    }

    private func editorFixture(fileURL: URL? = nil) -> EditorFixture {
        let project = VideoProject()
        project.fileURL = fileURL
        project.fileType = VideoProject.typeIdentifier
        let window = NonKeyEditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = EditorWindowController(
            editorViewModel: project.editorViewModel,
            window: window,
            onWindowDidBecomeKey: { [weak project] in
                guard let project else { return }
                AppState.shared.projectWindowDidBecomeKey(project)
            }
        )
        project.addWindowController(controller)
        return EditorFixture(
            project: project,
            window: window,
            controller: controller
        )
    }

    private func resetToHome() -> NSWindow {
        _ = NSApplication.shared
        AppState.shared.showHome(persist: false)
        HomeWindowController.shared.showWindow(nil)
        return HomeWindowController.shared.window!
    }

    private func register(_ projects: [VideoProject]) {
        for project in projects {
            NSDocumentController.shared.addDocument(project)
        }
    }

    private func cleanUp(_ projects: [VideoProject]) {
        AppState.shared.showHome(persist: false)
        for project in projects {
            project.windowControllers.forEach { $0.window?.orderOut(nil) }
            NSDocumentController.shared.removeDocument(project)
            if let url = project.fileURL {
                ProjectRegistry.shared.remove(url)
            }
        }
    }

    private func keyNotification(for controller: EditorWindowController) -> Notification {
        Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: controller.window
        )
    }
}

@MainActor
private struct EditorFixture {
    let project: VideoProject
    let window: NSWindow
    let controller: EditorWindowController
}

@MainActor
private final class NonKeyEditorWindow: NSWindow {
    override var canBecomeKey: Bool { false }
}
