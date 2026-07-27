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
    /// The active pack's brand accent (from its manifest), or nil when no pack is active or it declares
    /// none. Surfaces that want to render a control in the pack's colors (the in-chat upload well) fall
    /// back to `AppTheme.Accent.primary` when this is nil.
    var activePackAccentColor: Color? {
        guard let name = activePluginName,
              let hex = PackCatalog.pack(named: name)?.manifest.accentHex
        else { return nil }
        return Color(hex: hex)
    }
}
