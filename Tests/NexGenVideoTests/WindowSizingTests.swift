import AppKit
import Testing

@testable import NexGenVideo

@Suite("Editor window default sizing")
struct WindowSizingTests {

    // A small laptop screen: the default must fit inside it (never exceed the desktop) with
    // real editor height, not the 1600×1000 cap.
    @Test func defaultFitsASmallScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 812)  // 13" after menu bar
        let size = VideoProject.defaultProjectContentSize(visible: visible)
        #expect(size.width <= visible.width)
        #expect(size.height <= visible.height)
        #expect(size.width >= AppTheme.Window.projectMin.width)
        #expect(size.height >= AppTheme.Window.projectMin.height)
        #expect(size.height > 700)  // enough height for a usable editor
    }

    // A desktop smaller than projectMin (a small external display or a scaled "more space"
    // mode): the "never exceed the visible desktop" invariant wins over the projectMin floor.
    @Test func defaultNeverExceedsATinyScreen() {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 500)  // below projectMin 960×600
        let size = VideoProject.defaultProjectContentSize(visible: visible)
        #expect(size.width <= visible.width)
        #expect(size.height <= visible.height)
    }

    // A large display: the default is capped at projectDefault, not the full screen.
    @Test func defaultCapsOnBigScreen() {
        let visible = NSRect(x: 0, y: 0, width: 3840, height: 2160)
        let size = VideoProject.defaultProjectContentSize(visible: visible)
        #expect(size.width == AppTheme.Window.projectDefault.width)
        #expect(size.height == AppTheme.Window.projectDefault.height)
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
}
