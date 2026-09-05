import NexGenEngine
import SwiftUI

extension Color {
    /// Parse a `#RRGGBB` (or `RRGGBB`) hex string into a Color. Nil for malformed input so callers
    /// fall back to a default accent rather than rendering a wrong color.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: AppTheme.Opacity.opaque
        )
    }
}

extension EditorViewModel {
    var projectPalette: ProjectPalette {
        guard packWiringBroken == nil,
              let name = activePluginName,
              let pack = PackCatalog.pack(named: name) else { return .neutral }
        if let binding = declaredPluginBinding,
           binding.id != pack.name || binding.version != pack.version { return .neutral }
        return .resolve(hex: pack.manifest.accentHex)
    }

    var activePackAccentColor: Color? {
        activePluginName == nil ? nil : projectPalette.accent
    }
}
