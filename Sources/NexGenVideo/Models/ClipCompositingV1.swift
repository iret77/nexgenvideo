import Foundation

enum ClipBlendMode: String, CaseIterable, Codable, Sendable {
    case normal, darken, multiply, colorBurn, lighten, screen, colorDodge
    case overlay, softLight, hardLight, difference, exclusion
    case hue, saturation, color, luminosity

    var title: String {
        switch self {
        case .colorBurn: "Color Burn"
        case .colorDodge: "Color Dodge"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    var filterName: String? {
        switch self {
        case .normal: nil
        case .darken: "CIDarkenBlendMode"
        case .multiply: "CIMultiplyBlendMode"
        case .colorBurn: "CIColorBurnBlendMode"
        case .lighten: "CILightenBlendMode"
        case .screen: "CIScreenBlendMode"
        case .colorDodge: "CIColorDodgeBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .softLight: "CISoftLightBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        case .difference: "CIDifferenceBlendMode"
        case .exclusion: "CIExclusionBlendMode"
        case .hue: "CIHueBlendMode"
        case .saturation: "CISaturationBlendMode"
        case .color: "CIColorBlendMode"
        case .luminosity: "CILuminosityBlendMode"
        }
    }
}

// Host-only carrier; no NexGenEngine or pack value layout changes.
struct ClipCompositingV1: Codable, Sendable, Equatable {
    var version: Int = 1
    var blendMode: String

    var supportedMode: ClipBlendMode? {
        version == 1 ? ClipBlendMode(rawValue: blendMode) : nil
    }
}

extension Clip {
    var blendMode: ClipBlendMode {
        get { mediaType == .audio ? .normal : compositing?.supportedMode ?? .normal }
        set { compositing = newValue == .normal ? nil : ClipCompositingV1(blendMode: newValue.rawValue) }
    }

    var blendModeTitle: String {
        if let compositing, compositing.supportedMode == nil { return "Normal (Unsupported Mode)" }
        return blendMode.title
    }
}
