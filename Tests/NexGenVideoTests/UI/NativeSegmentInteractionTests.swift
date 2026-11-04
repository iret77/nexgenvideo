import AppKit
import Testing
@testable import NexGenVideo

@Suite("Native segment interaction geometry", .serialized)
@MainActor
struct NativeSegmentInteractionTests {
    @MainActor
    private final class Fixture {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let probe = NSView(frame: NSRect(x: 20, y: 20, width: 373, height: 24))
        let control = NSSegmentedControl(frame: NSRect(x: 151, y: 0, width: 222, height: 24))
        let driver: ProductionVisualSourcesDriver

        init() {
            window.contentView = root
            root.addSubview(probe)
            probe.addSubview(control)
            control.segmentCount = 2
            control.setLabel("Design", forSegment: 0)
            control.setLabel("Locations · 3D", forSegment: 1)
            control.setEnabled(true, forSegment: 1)
            driver = ProductionVisualSourcesDriver(window: window, output: FileManager.default.temporaryDirectory,
                                                   name: "segment-geometry")
        }

        func screen(_ native: NSRect) -> NSRect {
            window.convertToScreen(control.convert(native, to: nil))
        }

        func interaction(_ native: NSRect = NSRect(x: 112, y: -1, width: 112, height: 24)) -> NSRect? {
            driver.segmentInteractionGeometry(screen(native), control: control, segmentIndex: 1, probe: probe, in: window).frame
        }
    }

    @Test func nativeDecorationOutsideTheProbeUsesActualPointerBounds() throws {
        let fixture = Fixture()
        let raw = NSRect(x: 112, y: -1, width: 112, height: 24)
        #expect(!fixture.probe.bounds.contains(fixture.probe.convert(raw, from: fixture.control)))
        let interaction = try #require(fixture.interaction(raw))
        #expect(interaction == NSRect(x: 263, y: 0, width: 110, height: 23))
        let point = fixture.probe.convert(NSPoint(x: interaction.midX, y: interaction.midY), to: fixture.root)
        #expect(fixture.root.hitTest(point) === fixture.control)
    }

    @Test func disabledSegmentCannotProduceAnInteractionFrame() {
        let fixture = Fixture()
        fixture.control.setEnabled(false, forSegment: 1)
        #expect(fixture.interaction() == nil)
    }

    @Test func disabledControlCannotProduceAnInteractionFrame() {
        let fixture = Fixture()
        fixture.control.isEnabled = false
        #expect(fixture.interaction() == nil)
    }

    @Test func clippedControlIsRejectedEvenWhenTheTargetSegmentIsVisible() {
        let fixture = Fixture()
        let clip = NSView(frame: NSRect(x: 20, y: 20, width: 213, height: 24))
        clip.clipsToBounds = true
        fixture.probe.removeFromSuperview()
        fixture.probe.setFrameOrigin(NSPoint(x: -160, y: 0))
        clip.addSubview(fixture.probe)
        fixture.root.addSubview(clip)
        let nativeTarget = NSRect(x: 112, y: 0, width: 110, height: 23)
        #expect(!fixture.control.visibleRect.contains(fixture.control.bounds))
        #expect(fixture.control.visibleRect.contains(nativeTarget))
        let center = fixture.control.convert(NSPoint(x: nativeTarget.midX, y: nativeTarget.midY), to: fixture.root)
        #expect(fixture.root.hitTest(center) === fixture.control)
        #expect(fixture.interaction() == nil)
    }

    @Test func coveredPointerTargetIsRejected() {
        let fixture = Fixture()
        let point = fixture.control.convert(NSPoint(x: 167, y: 11.5), to: fixture.root)
        let cover = NSView(frame: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        fixture.root.addSubview(cover)
        #expect(fixture.root.hitTest(point) === cover)
        #expect(fixture.interaction() == nil)
    }

    @Test func accessibilityCenterOutsideTheNativeControlIsRejected() {
        let fixture = Fixture()
        #expect(fixture.interaction(NSRect(x: 220, y: 0, width: 8, height: 24)) == nil)
    }

    @Test func hiddenControlIsRejected() {
        let fixture = Fixture()
        fixture.control.isHidden = true
        #expect(fixture.interaction() == nil)
    }

    @Test func emptyAndNonfiniteAccessibilityFramesAreRejected() {
        let fixture = Fixture()
        #expect(fixture.interaction(NSRect(x: 112, y: 0, width: 0, height: 24)) == nil)
        #expect(fixture.driver.segmentInteractionGeometry(NSRect(x: CGFloat.nan, y: 0, width: 112, height: 24),
            control: fixture.control, segmentIndex: 1, probe: fixture.probe, in: fixture.window).frame == nil)
    }

    @Test func accessibilityFrameCannotBorrowAnotherWindow() {
        let fixture = Fixture()
        let foreign = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 200),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        #expect(fixture.driver.segmentInteractionGeometry(fixture.screen(NSRect(x: 112, y: -1, width: 112, height: 24)),
            control: fixture.control, segmentIndex: 1, probe: fixture.probe, in: foreign).frame == nil)
    }
}
