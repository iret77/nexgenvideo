import AppKit
import Testing

@testable import NexGenVideo

@Suite("Editor window default sizing")
struct WindowSizingTests {

    // A small laptop screen: the default must fit inside it (never exceed the desktop) with
    // real editor height — a screen fraction here, well below the projectDefault cap.
    @Test func defaultFitsASmallScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 812)  // 13" after menu bar
        let size = VideoProject.defaultProjectContentSize(visible: visible)
        #expect(size.width <= visible.width)
        #expect(size.height <= visible.height)
        #expect(size.width >= AppTheme.Window.projectMin.width)
        #expect(size.height >= AppTheme.Window.projectMin.height)
        #expect(abs(size.height - 779.52) < 0.01)
    }

    // A desktop smaller than projectMin (a small external display or a scaled "more space"
    // mode): the "never exceed the visible desktop" invariant wins over the projectMin floor.
    @Test func defaultNeverExceedsATinyScreen() {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 500)  // below projectMin 960×600
        let size = VideoProject.defaultProjectContentSize(visible: visible)
        #expect(size.width <= visible.width)
        #expect(size.height <= visible.height)
    }

    // A large display gets the explicitly approved taller 2560×1800 editor, not the old 2560×1600.
    @Test func defaultIsTallerOnBigScreen() {
        let visible = NSRect(x: 0, y: 0, width: 3840, height: 2160)
        let size = VideoProject.defaultProjectContentSize(visible: visible)
        #expect(size.width == 2560)
        #expect(size.height == 1800)
    }

    @Test func defaultIsTallerAtRetinaFiveKPointSize() {
        let visible = NSRect(x: 0, y: 0, width: 2560, height: 1415)
        let size = VideoProject.defaultProjectContentSize(visible: visible)
        #expect(abs(size.width - 2252.8) < 0.01)
        #expect(abs(size.height - 1358.4) < 0.01)
    }

    @Test func tallerDefaultRetiresThePreviousSavedFrameOnce() {
        #expect(VideoProject.projectWindowFrameAutosaveName == "NexGenVideoWindow-v5")
    }

    // A frame saved on a larger, since-disconnected display is shrunk + nudged fully on-screen.
    @Test func clampBringsAnOversizedFrameOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 812)
        let oversized = NSRect(x: 1200, y: 700, width: 2400, height: 1500)
        let f = VideoProject.clampToScreen(oversized, visible: visible)
        #expect(f.width <= visible.width)
        #expect(f.height <= visible.height)
        #expect(f.minX >= visible.minX)
        #expect(f.minY >= visible.minY)
        #expect(f.maxX <= visible.maxX)
        #expect(f.maxY <= visible.maxY)
    }

    // An already-fitting frame is returned unchanged.
    @Test func clampLeavesAFittingFrameAlone() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let ok = NSRect(x: 100, y: 100, width: 1200, height: 800)
        #expect(VideoProject.clampToScreen(ok, visible: visible) == ok)
    }

    @Test func restoredHomeFrameGrowsToCurrentMinimum() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 812)
        let stale = NSRect(x: 120, y: 100, width: 760, height: 500)
        let restored = WindowGeometry.restoredFrame(
            stale, minimum: AppTheme.Window.homeMin, visible: visible
        )
        #expect(restored.width == AppTheme.Window.homeMin.width)
        #expect(restored.height == AppTheme.Window.homeMin.height)
    }

    @Test func restoredUserSizeIsPreservedWhenItFits() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let chosen = NSRect(x: 200, y: 120, width: 1100, height: 780)
        #expect(WindowGeometry.restoredFrame(
            chosen, minimum: AppTheme.Window.homeMin, visible: visible
        ) == chosen)
    }

    @Test func restoredHomeFrameNeverExceedsTinyScreen() {
        let visible = NSRect(x: 0, y: 0, width: 700, height: 600)
        let stale = NSRect(x: 900, y: 800, width: 600, height: 400)
        let restored = WindowGeometry.restoredFrame(
            stale, minimum: AppTheme.Window.homeMin, visible: visible
        )
        #expect(restored.width <= visible.width)
        #expect(restored.height <= visible.height)
        #expect(visible.contains(restored))
    }
}
