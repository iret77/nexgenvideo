import AppKit
import Testing

@testable import NexGenVideo

@Suite("Project window presentation", .serialized)
@MainActor
struct ProjectWindowPresentationTests {
    @Test("Home yields only after the project window key event")
    func homeWaitsForProjectWindowKeyEvent() throws {
        _ = NSApplication.shared
        let project = VideoProject()
        HomeWindowController.shared.showWindow(nil)
        defer { cleanUp([project]) }

        project.makeWindowControllers()
        let controller = try #require(project.windowControllers.first as? EditorWindowController)
        let editorWindow = try #require(controller.window)

        #expect(editorWindow.delegate === controller)
        #expect(!editorWindow.isVisible)
        #expect(AppState.shared.activeProject !== project)
        #expect(HomeWindowController.shared.window?.isVisible == true)

        editorWindow.orderFront(nil)

        #expect(editorWindow.isVisible)
        #expect(editorWindow.canBecomeKey)
        #expect(HomeWindowController.shared.window?.isVisible == true)

        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: editorWindow)
        )

        #expect(AppState.shared.activeProject === project)
        #expect(editorWindow.isVisible)
        #expect(HomeWindowController.shared.window?.isVisible == false)
    }

    @Test("cancel and failure leave Home operable without a key event")
    func abortedPresentationKeepsHomeVisible() throws {
        _ = NSApplication.shared
        let cancelledProject = VideoProject()
        let failedProject = VideoProject()
        HomeWindowController.shared.showWindow(nil)
        defer { cleanUp([cancelledProject, failedProject]) }

        cancelledProject.makeWindowControllers()
        failedProject.makeWindowControllers()
        let cancelledWindow = try #require(cancelledProject.windowControllers.first?.window)
        let failedWindow = try #require(failedProject.windowControllers.first?.window)

        cancelledWindow.orderFront(nil)
        cancelledWindow.orderOut(nil)
        failedWindow.orderFront(nil)
        failedWindow.orderOut(nil)

        #expect(AppState.shared.activeProject !== cancelledProject)
        #expect(AppState.shared.activeProject !== failedProject)
        #expect(HomeWindowController.shared.window?.isVisible == true)
        #expect(HomeWindowController.shared.window?.canBecomeKey == true)
    }

    @Test("repeated and multiwindow key events select an operable project")
    func repeatedMultiwindowEventsRemainOperable() throws {
        _ = NSApplication.shared
        let first = VideoProject()
        let second = VideoProject()
        HomeWindowController.shared.showWindow(nil)
        defer { cleanUp([first, second]) }

        first.makeWindowControllers()
        second.makeWindowControllers()
        let firstController = try #require(first.windowControllers.first as? EditorWindowController)
        let secondController = try #require(second.windowControllers.first as? EditorWindowController)
        let firstWindow = try #require(firstController.window)
        let secondWindow = try #require(secondController.window)
        firstWindow.orderFront(nil)
        secondWindow.orderFront(nil)

        firstController.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: firstWindow)
        )
        firstController.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: firstWindow)
        )

        #expect(AppState.shared.activeProject === first)
        #expect(firstWindow.isVisible)
        #expect(HomeWindowController.shared.window?.isVisible == false)

        HomeWindowController.shared.showWindow(nil)
        secondController.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: secondWindow)
        )

        #expect(AppState.shared.activeProject === second)
        #expect(secondWindow.isVisible)
        #expect(HomeWindowController.shared.window?.isVisible == false)
    }

    @Test("closing the active project promotes another open project")
    func closingActiveProjectKeepsAProjectWindowAvailable() throws {
        _ = NSApplication.shared
        let first = VideoProject()
        let second = VideoProject()
        NSDocumentController.shared.addDocument(first)
        NSDocumentController.shared.addDocument(second)
        HomeWindowController.shared.showWindow(nil)
        defer {
            NSDocumentController.shared.removeDocument(first)
            NSDocumentController.shared.removeDocument(second)
            cleanUp([first, second])
        }

        first.makeWindowControllers()
        second.makeWindowControllers()
        let firstController = try #require(first.windowControllers.first as? EditorWindowController)
        let firstWindow = try #require(firstController.window)
        firstWindow.orderFront(nil)
        firstController.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: firstWindow)
        )

        NSDocumentController.shared.removeDocument(first)
        AppState.shared.projectDidClose(first)

        #expect(AppState.shared.activeProject === second)
        #expect(second.windowControllers.first?.window?.isVisible == true)
        #expect(HomeWindowController.shared.window?.isVisible == false)
    }

    @Test("Dock reopen restores Home when no window is visible")
    func reopenRestoresHome() {
        _ = NSApplication.shared
        AppState.shared.showHome(persist: false)
        HomeWindowController.shared.window?.orderOut(nil)
        defer { HomeWindowController.shared.window?.orderOut(nil) }

        let handled = AppDelegate().applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        )

        #expect(handled)
        #expect(HomeWindowController.shared.window?.isVisible == true)
        #expect(HomeWindowController.shared.window?.canBecomeKey == true)
    }

    private func cleanUp(_ projects: [VideoProject]) {
        if projects.contains(where: { AppState.shared.activeProject === $0 }) {
            AppState.shared.showHome(persist: false)
        }
        for project in projects {
            for controller in project.windowControllers {
                controller.window?.orderOut(nil)
                project.removeWindowController(controller)
            }
        }
        HomeWindowController.shared.window?.orderOut(nil)
    }
}
