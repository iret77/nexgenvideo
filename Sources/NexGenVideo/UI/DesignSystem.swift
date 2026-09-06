import AppKit
import SwiftUI

extension AppTheme {
    enum Typography {
        static let metadata: CGFloat = 11
        static let ui: CGFloat = 13
        static let action: CGFloat = 13
        static let reading: CGFloat = 14
        static let section: CGFloat = 15
        static let title: CGFloat = 20
        static let display: CGFloat = 28
        static let hero: CGFloat = 36
        static let readingLineSpacing: CGFloat = 6
        static let standardScale: Double = 1
        static let largeScale: Double = 1.25
        static let largestScale: Double = 1.5
        static let scaleKey = "interfaceTextScale"

        static func validatedScale(_ value: Double) -> Double {
            [standardScale, largeScale, largestScale].contains(value) ? value : standardScale
        }
    }

    enum Control {
        static let regularHeight: CGFloat = 32
        static let compactHeight: CGFloat = 28
        static let regularRowHeight: CGFloat = 40
        static let iconTarget: CGFloat = 28
    }
}

struct ProjectPalette: Equatable {
    let identity: Color
    let accent: Color
    let onAccent: Color

    static let neutral = Self(identity: AppTheme.Accent.primary, accent: AppTheme.Accent.primary,
                              onAccent: AppTheme.Background.baseColor)

    static func resolve(hex: String?) -> Self {
        guard let hex, let parsed = Color(hex: hex),
              let rgb = NSColor(parsed).usingColorSpace(.sRGB) else { return .neutral }
        let base = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        let background = AppTheme.Background.prominent
        let surface = luminance([background.redComponent, background.greenComponent, background.blueComponent])
        var components = base
        for step in 0...100 {
            let mix = CGFloat(step) / 100
            components = base.map { $0 + (1 - $0) * mix }
            if (luminance(components) + 0.05) / (surface + 0.05) >= 4.5 { break }
        }
        let color = Color(.sRGB, red: components[0], green: components[1], blue: components[2])
        return Self(identity: parsed, accent: color, onAccent: AppTheme.Background.baseColor)
    }

    static func luminance(_ components: [CGFloat]) -> CGFloat {
        let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
}

private struct ProjectPaletteKey: EnvironmentKey {
    static let defaultValue = ProjectPalette.neutral
}
private struct InterfaceScaleKey: EnvironmentKey {
    static let defaultValue = AppTheme.Typography.standardScale
}
extension EnvironmentValues {
    var projectPalette: ProjectPalette {
        get { self[ProjectPaletteKey.self] }
        set { self[ProjectPaletteKey.self] = newValue }
    }
    var interfaceScale: Double {
        get { self[InterfaceScaleKey.self] }
        set { self[InterfaceScaleKey.self] = newValue }
    }
}

private struct InterfaceStyle: ViewModifier {
    let palette: ProjectPalette
    @AppStorage(AppTheme.Typography.scaleKey) private var savedScale = AppTheme.Typography.standardScale

    func body(content: Content) -> some View {
        let scale = AppTheme.Typography.validatedScale(savedScale)
        content
            .environment(\.projectPalette, palette)
            .environment(\.interfaceScale, scale)
            .tint(palette.accent)
            .font(.system(size: AppTheme.Typography.ui * scale))
    }
}

private struct InterfaceFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

private struct WorkspaceHeaderContent: ViewModifier {
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content.frame(height: AppTheme.Layout.workspaceHeaderHeight * scale)
    }
}

struct ProjectInterface<Content: View>: View {
    @Environment(EditorViewModel.self) private var editor
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.interfaceStyle(palette: editor.projectPalette) }
}

extension View {
    func workspaceHeaderContent() -> some View {
        modifier(WorkspaceHeaderContent())
    }

    func interfaceStyle(palette: ProjectPalette = .neutral) -> some View {
        modifier(InterfaceStyle(palette: palette))
    }

    func interfaceFont(size: CGFloat, weight: Font.Weight = AppTheme.FontWeight.regular,
                       design: Font.Design = .default) -> some View {
        modifier(InterfaceFont(size: size, weight: weight, design: design))
    }
}
