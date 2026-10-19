import AppKit
import Testing
@testable import NexGenVideo

@MainActor
struct TrackResizeIdentityTests {
    @Test func resizeFollowsItsTrackAcrossReorderAndUndo() throws {
        let (editor, header, undo, window) = fixture()
        defer { window.close() }
        let originalHeight = editor.timeline.tracks[1].displayHeight
        try begin(1, header: header, editor: editor)
        editor.timeline.tracks.swapAt(0, 1)
        try drag(0, height: 100, header: header, editor: editor)
        #expect(editor.timeline.tracks[0].id == "resized")
        #expect(editor.timeline.tracks[0].displayHeight == 100)
        #expect(editor.timeline.tracks[1].displayHeight == originalHeight)
        editor.timeline.tracks.swapAt(0, 1)
        header.mouseUp(with: try event(.leftMouseUp, at: .zero, in: header))
        #expect(editor.timeline.tracks[1].displayHeight == 100)
        #expect(undo.undoActionName == "Resize Track")
        undo.undo()
        #expect(editor.timeline.tracks.map(\.id) == ["untouched", "resized"])
        #expect(editor.timeline.tracks.allSatisfy { $0.displayHeight == originalHeight })
    }

    @Test func deletingTheTrackBeforeDragCannotResizeItsReplacement() throws {
        let (editor, header, undo, window) = fixture()
        defer { window.close() }
        try begin(1, header: header, editor: editor)
        editor.timeline.tracks.removeLast()
        editor.timeline.tracks.append(Track(id: "replacement", type: .video))
        let before = editor.timeline
        try drag(1, height: 100, header: header, editor: editor)
        header.mouseUp(with: try event(.leftMouseUp, at: .zero, in: header))
        #expect(editor.timeline == before)
        #expect(!undo.canUndo)
    }

    @Test func deletingTheTrackBeforeMouseUpEndsWithoutAnUndo() throws {
        let (editor, header, undo, window) = fixture()
        defer { window.close() }
        try begin(1, header: header, editor: editor)
        try drag(1, height: 100, header: header, editor: editor)
        editor.timeline.tracks.removeLast()
        let before = editor.timeline
        header.mouseUp(with: try event(.leftMouseUp, at: .zero, in: header))
        #expect(editor.timeline == before)
        #expect(!undo.canUndo)
    }

    private func fixture() -> (EditorViewModel, TimelineHeaderView, UndoManager, NSWindow) {
        _ = NSApplication.shared
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.timeline.tracks = [Track(id: "untouched", type: .video), Track(id: "resized", type: .video)]
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let header = TimelineHeaderView(editor: editor)
        header.frame = NSRect(x: 0, y: 0, width: 200, height: 500)
        let window = NSWindow(contentRect: header.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = header
        return (editor, header, undo, window)
    }

    private func begin(_ index: Int, header: TimelineHeaderView, editor: EditorViewModel) throws {
        let geometry = TimelineGeometry(editor: editor, bounds: header.bounds)
        let point = NSPoint(x: 100, y: geometry.trackY(at: index) + geometry.trackHeight(at: index))
        header.mouseDown(with: try event(.leftMouseDown, at: point, in: header))
    }

    private func drag(_ index: Int, height: CGFloat, header: TimelineHeaderView, editor: EditorViewModel) throws {
        let geometry = TimelineGeometry(editor: editor, bounds: header.bounds)
        let point = NSPoint(x: 100, y: geometry.trackY(at: index) + height)
        header.mouseDragged(with: try event(.leftMouseDragged, at: point, in: header))
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in header: TimelineHeaderView) throws -> NSEvent {
        let window = try #require(header.window)
        return try #require(NSEvent.mouseEvent(with: type, location: header.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
