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
    private var raw: JSONValue

    init(version: Int = 1, blendMode: String) {
        raw = .object(["version": .number(Decimal(version)), "blendMode": .string(blendMode)])
    }

    init(from decoder: Decoder) throws { raw = try JSONValue(from: decoder) }

    func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }

    var supportedMode: ClipBlendMode? {
        guard case .object(let fields) = raw,
              fields["version"] == .number(1),
              let rawMode = fields["blendMode"],
              case .string(let mode) = rawMode else { return nil }
        return ClipBlendMode(rawValue: mode)
    }

    private indirect enum JSONValue: Codable, Sendable, Equatable {
        case object([String: JSONValue]), array([JSONValue]), string(String), number(Decimal), floating(Double), bool(Bool), null

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
            else if let string = try? value.decode(String.self) { self = .string(string) }
            else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
            else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
            else if let number = try? value.decode(Decimal.self) { self = .number(number) }
            else { self = .floating(try value.decode(Double.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .object(let object): try value.encode(object)
            case .array(let array): try value.encode(array)
            case .string(let string): try value.encode(string)
            case .number(let number): try value.encode(number)
            case .floating(let number): try value.encode(number)
            case .bool(let bool): try value.encode(bool)
            case .null: try value.encodeNil()
            }
        }
    }
}

extension Clip {
    var blendMode: ClipBlendMode {
        get { mediaType.isVisual ? compositing?.supportedMode ?? .normal : .normal }
        set { compositing = newValue == .normal ? nil : ClipCompositingV1(blendMode: newValue.rawValue) }
    }

    var blendModeTitle: String {
        if let compositing, compositing.supportedMode == nil { return "Normal (Unsupported Mode)" }
        return blendMode.title
    }
}
