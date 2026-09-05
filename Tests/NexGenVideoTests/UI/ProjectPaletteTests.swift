import AppKit
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Project palette")
struct ProjectPaletteTests {
    @Test(arguments: ["#FF2D55", "#00FF00", "#FFFF00", "#000000", "#FFFFFF", "#001020"])
    func accentRemainsReadable(hex: String) throws {
        let palette = ProjectPalette.resolve(hex: hex)
        let color = try #require(NSColor(palette.accent).usingColorSpace(.sRGB))
        let foreground = ProjectPalette.luminance([color.redComponent, color.greenComponent, color.blueComponent])
        let background = AppTheme.Background.prominent
        let behind = ProjectPalette.luminance([background.redComponent, background.greenComponent, background.blueComponent])
        #expect((foreground + 0.05) / (behind + 0.05) >= 4.5)
        let text = AppTheme.Background.base
        let textLuminance = ProjectPalette.luminance([text.redComponent, text.greenComponent, text.blueComponent])
        #expect((foreground + 0.05) / (textLuminance + 0.05) >= 4.5)
    }

    @Test func missingAndInvalidColorsAreNeutral() {
        #expect(ProjectPalette.resolve(hex: nil) == .neutral)
        #expect(ProjectPalette.resolve(hex: "#xyzxyz") == .neutral)
    }

    @Test func resolvingAnotherProjectDoesNotChangeAnExistingPalette() {
        let first = ProjectPalette.resolve(hex: "#FF2D55")
        let second = ProjectPalette.resolve(hex: "#3388FF")
        #expect(first != second)
        #expect(first == ProjectPalette.resolve(hex: "#FF2D55"))
    }

    @Test(arguments: [Double.nan, Double.infinity, -1, 0, 9])
    func invalidPersistedScaleIsBounded(value: Double) {
        #expect(AppTheme.Typography.validatedScale(value) == 1)
    }
}
