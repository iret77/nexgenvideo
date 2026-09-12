import Foundation
import Testing

@testable import NexGenVideo

@MainActor
@Suite("Project window presentation", .serialized)
struct ProjectWindowPresentationTests {
    @Test("new-project completion registers the recent before constructing and presenting")
    func newProjectSuccessOrdering() {
        let state = AppState()
        let project = VideoProject()
        let recorder = PresentationRecorder()
        let request = ProjectWindowPresentationRequest.newProject(
            project: project,
            url: URL(fileURLWithPath: "/tmp/New.ngv")
        )

        let result = state.completeProjectPresentation(
            .ready(request),
            effects: recorder.presentationEffects
        )

        #expect(result == .presented)
        #expect(recorder.events == [.registerRecent, .createWindows, .present])
        #expect(state.activeProject == nil)
    }

    @Test("loaded-project completion registers the document before constructing and presenting")
    func openProjectSuccessOrdering() {
        let state = AppState()
        let project = VideoProject()
        let recorder = PresentationRecorder()
        let request = ProjectWindowPresentationRequest.loadedProject(
            project: project,
            url: URL(fileURLWithPath: "/tmp/Open.ngv"),
            registerRecent: true,
            options: ProjectOpenOptions(startTutorial: true)
        )

        let result = state.completeProjectPresentation(
            .ready(request),
            effects: recorder.presentationEffects
        )

        #expect(result == .presented)
        #expect(
            recorder.events == [
                .addDocument,
                .registerRecent,
                .applyOptions,
                .createWindows,
                .present,
            ]
        )
        #expect(state.activeProject == nil)
    }

    @Test("cancelled new-project completion has no presentation effects")
    func newProjectCancellationDoesNothing() {
        let state = AppState()
        let recorder = PresentationRecorder()

        let result = state.completeProjectPresentation(
            .cancelled,
            effects: recorder.presentationEffects
        )

        #expect(result == .cancelled)
        #expect(recorder.events.isEmpty)
        #expect(state.activeProject == nil)
    }

    @Test("rejected open validation has no document or presentation effects")
    func openValidationRejectionDoesNothing() {
        let state = AppState()
        let recorder = PresentationRecorder()

        let accepted = state.acceptProjectOpenValidation(
            false,
            effects: recorder.presentationEffects
        )

        #expect(!accepted)
        #expect(!recorder.events.contains(.addDocument))
        #expect(!recorder.events.contains(.createWindows))
        #expect(!recorder.events.contains(.present))
        #expect(state.activeProject == nil)
    }

    @Test("failed new-project completion unregisters before reporting the error")
    func newProjectFailureOrdering() {
        let state = AppState()
        let project = VideoProject()
        let recorder = PresentationRecorder()

        let result = state.completeProjectPresentation(
            .failed(TestFailure.expected, discard: project),
            effects: recorder.presentationEffects
        )

        #expect(result == .failed)
        #expect(recorder.events == [.removeDocument, .reportError])
        #expect(state.activeProject == nil)
    }

    @Test("failed open reports the error without registering or presenting")
    func openFailureDoesNotPresent() {
        let state = AppState()
        let recorder = PresentationRecorder()

        let result = state.completeProjectPresentation(
            .failed(TestFailure.expected, discard: nil),
            effects: recorder.presentationEffects
        )

        #expect(result == .failed)
        #expect(recorder.events == [.reportError])
        #expect(state.activeProject == nil)
    }

    @Test("rapid opens follow key-event order, not completion order")
    func rapidSuccessiveOpensFollowKeyEventOrder() {
        let state = AppState()
        let first = VideoProject()
        let second = VideoProject()
        let recorder = PresentationRecorder()

        _ = state.completeProjectPresentation(
            .ready(.existingProject(
                project: first,
                url: URL(fileURLWithPath: "/tmp/First.ngv"),
                registerRecent: true,
                options: .init()
            )),
            effects: recorder.presentationEffects
        )
        _ = state.completeProjectPresentation(
            .ready(.existingProject(
                project: second,
                url: URL(fileURLWithPath: "/tmp/Second.ngv"),
                registerRecent: true,
                options: .init()
            )),
            effects: recorder.presentationEffects
        )
        #expect(state.activeProject == nil)

        state.projectWindowDidBecomeKey(
            second,
            effects: recorder.activationEffects
        )

        #expect(state.activeProject === second)
    }

    @Test("switching key editors updates the active project each time")
    func keyWindowSwitchesActiveProject() {
        let state = AppState()
        let first = VideoProject()
        let second = VideoProject()
        let recorder = PresentationRecorder()

        state.projectWindowDidBecomeKey(first, effects: recorder.activationEffects)
        #expect(state.activeProject === first)

        state.projectWindowDidBecomeKey(second, effects: recorder.activationEffects)
        #expect(state.activeProject === second)

        state.projectWindowDidBecomeKey(first, effects: recorder.activationEffects)
        #expect(state.activeProject === first)
    }

    @Test("returning Home clears the active project and reopening waits for key")
    func homeThenReopenRepeatsActivationGate() {
        let state = AppState()
        let project = VideoProject()
        let recorder = PresentationRecorder()

        state.projectWindowDidBecomeKey(project, effects: recorder.activationEffects)
        #expect(state.activeProject === project)

        state.projectWindowPresentationDidEnd(project)
        #expect(state.activeProject == nil)

        _ = state.completeProjectPresentation(
            .ready(.existingProject(
                project: project,
                url: URL(fileURLWithPath: "/tmp/Reopen.ngv"),
                registerRecent: true,
                options: .init()
            )),
            effects: recorder.presentationEffects
        )
        #expect(state.activeProject == nil)

        state.projectWindowDidBecomeKey(project, effects: recorder.activationEffects)
        #expect(state.activeProject === project)
    }

    @Test("notification presentation does not activate before the key callback")
    func notificationPresentationWaitsForKeyWindow() {
        let state = AppState()
        let project = VideoProject()
        let recorder = PresentationRecorder()

        let result = state.completeProjectPresentation(
            .ready(.notification(project: project)),
            effects: recorder.presentationEffects
        )

        #expect(result == .presented)
        #expect(recorder.events == [.present])
        #expect(state.activeProject == nil)

        state.projectWindowDidBecomeKey(project, effects: recorder.activationEffects)

        #expect(state.activeProject === project)
        #expect(recorder.events.last == .hideHome)
    }

    @Test("an unregistered key callback cannot activate or hide Home")
    func unregisteredEditorCannotActivate() {
        let state = AppState()
        let project = VideoProject()
        let recorder = PresentationRecorder()
        recorder.documentIsRegistered = false

        state.projectWindowDidBecomeKey(project, effects: recorder.activationEffects)

        #expect(state.activeProject == nil)
        #expect(!recorder.events.contains(.hideHome))
    }

    @Test("a registered but invisible editor does not hide Home")
    func invisibleEditorDoesNotHideHome() {
        let state = AppState()
        let project = VideoProject()
        let recorder = PresentationRecorder()
        recorder.editorIsVisible = false

        state.projectWindowDidBecomeKey(project, effects: recorder.activationEffects)

        #expect(state.activeProject === project)
        #expect(!recorder.events.contains(.hideHome))
    }
}

@MainActor
private final class PresentationRecorder {
    var events: [PresentationEvent] = []
    var documentIsRegistered = true
    var editorIsVisible = true

    var presentationEffects: ProjectWindowPresentationEffects {
        ProjectWindowPresentationEffects(
            addDocument: { [weak self] _ in self?.events.append(.addDocument) },
            removeDocument: { [weak self] _ in self?.events.append(.removeDocument) },
            registerRecent: { [weak self] _ in self?.events.append(.registerRecent) },
            applyOptions: { [weak self] _, _ in self?.events.append(.applyOptions) },
            createWindows: { [weak self] _ in self?.events.append(.createWindows) },
            present: { [weak self] _ in self?.events.append(.present) },
            reportError: { [weak self] _ in self?.events.append(.reportError) }
        )
    }

    var activationEffects: ProjectWindowActivationEffects {
        ProjectWindowActivationEffects(
            documentIsRegistered: { [weak self] _ in
                self?.documentIsRegistered == true
            },
            editorIsVisible: { [weak self] _ in
                self?.editorIsVisible == true
            },
            hideHome: { [weak self] in self?.events.append(.hideHome) }
        )
    }
}

private enum PresentationEvent: Equatable {
    case addDocument
    case removeDocument
    case registerRecent
    case applyOptions
    case createWindows
    case present
    case reportError
    case hideHome
}

private enum TestFailure: Error {
    case expected
}
