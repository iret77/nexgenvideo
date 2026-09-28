import CryptoKit
import Foundation

enum FCPXMLVersion: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case v1_10 = "1.10"
    case v1_11 = "1.11"
    case v1_12 = "1.12"
    case v1_13 = "1.13"
    case v1_14 = "1.14"

    var id: String { rawValue }
    static let `default`: FCPXMLVersion = .v1_10

    init(named value: String?) throws {
        guard let value else {
            self = .default
            return
        }
        guard let version = Self(rawValue: value) else {
            throw ToolError("export_project: version must be 1.10, 1.11, 1.12, 1.13, or 1.14")
        }
        self = version
    }

    var compatibilityNote: String {
        switch self {
        case .v1_10: "Broadest supported interchange profile."
        case .v1_11: "Version-pinned 1.11 interchange profile."
        case .v1_12: "Version-pinned 1.12 interchange profile."
        case .v1_13: "Version-pinned 1.13 interchange profile."
        case .v1_14: "Current version-pinned interchange profile."
        }
    }
}

enum FCPXMLTarget: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case finalCutPro = "final-cut-pro"
    case resolve

    var id: String { rawValue }
    static let `default`: FCPXMLTarget = .finalCutPro

    init(named value: String?) throws {
        guard let value else {
            self = .default
            return
        }
        guard let target = Self(rawValue: value) else {
            throw ToolError("export_project: target must be final-cut-pro or resolve")
        }
        self = target
    }

    var displayName: String {
        switch self {
        case .finalCutPro: "Final Cut Pro"
        case .resolve: "DaVinci Resolve"
        }
    }
}

enum FCPXMLFeatureDisposition: String, Codable, Sendable, Equatable {
    case exported
    case exportedWithWarning = "exported_with_warning"
    case warningOnly = "warning_only"
}

struct FCPXMLFeatureSupport: Codable, Sendable, Equatable {
    let feature: String
    let disposition: FCPXMLFeatureDisposition
    let detail: String
    let versions: [FCPXMLVersion]
}

enum FCPXMLFeatureMatrix {
    static let rows: [FCPXMLFeatureSupport] = [
        .init(feature: "video", disposition: .exported,
              detail: "Placement, source range, speed, opacity, crop, and transforms.", versions: FCPXMLVersion.allCases),
        .init(feature: "audio", disposition: .exportedWithWarning,
              detail: "Placement and static gain export; fades and gain automation produce warnings.", versions: FCPXMLVersion.allCases),
        .init(feature: "captions", disposition: .exportedWithWarning,
              detail: "Caption text exports as editable Basic Titles; caption-role semantics produce a warning.", versions: FCPXMLVersion.allCases),
        .init(feature: "transform-keyframes", disposition: .exportedWithWarning,
              detail: "Position, scale, rotation, and opacity export; non-linear easing is approximated and warned.", versions: FCPXMLVersion.allCases),
        .init(feature: "source-timecode", disposition: .exported,
              detail: "Exact rational origin with container, Sony RTMD, then BWF precedence.", versions: FCPXMLVersion.allCases),
        .init(feature: "effects", disposition: .warningOnly,
              detail: "NexGenVideo effects have no stable FCPXML identity and are reported per clip.", versions: FCPXMLVersion.allCases),
        .init(feature: "color-metadata", disposition: .warningOnly,
              detail: "Timeline and source color-space metadata is not modeled; the target editor discovers source color metadata.", versions: FCPXMLVersion.allCases),
        .init(feature: "lottie", disposition: .warningOnly,
              detail: "Lottie sources require rendering before interchange and are reported per clip.", versions: FCPXMLVersion.allCases),
    ]

    static func rows(for version: FCPXMLVersion) -> [FCPXMLFeatureSupport] {
        rows.filter { $0.versions.contains(version) }
    }
}

struct FCPXMLWarning: Codable, Sendable, Equatable, Hashable {
    let code: String
    let clipID: String?
    let message: String
}

struct FCPXMLValidationReport: Codable, Sendable, Equatable {
    let version: FCPXMLVersion
    let schemaProfile: String
    let assetCount: Int
    let storyElementCount: Int
}

enum FCPXMLSchemaValidator {
    private static let timeAttributes: Set<String> = [
        "frameDuration", "start", "duration", "offset", "tcStart", "time", "value",
    ]
    private static let storyNames: Set<String> = ["asset-clip", "ref-clip", "video", "title"]

    static func schemaProfile(for version: FCPXMLVersion) -> String {
        "apple/fcpxml-dtd/\(version.rawValue)"
    }

    static func validate(_ data: Data, version: FCPXMLVersion) throws -> FCPXMLValidationReport {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.nodePreserveAll])
            document.dtd = try XMLDTD(data: try schemaData(for: version), options: [])
            try document.validate()
        } catch {
            throw ExportError.xmlValidationFailed(
                version: version.rawValue,
                reason: validationReason(error)
            )
        }

        guard let root = document.rootElement(),
              root.name == "fcpxml",
              root.attribute(forName: "version")?.stringValue == version.rawValue else {
            throw ExportError.xmlValidationFailed(
                version: version.rawValue,
                reason: "The root version does not match the selected export profile."
            )
        }

        var assetCount = 0
        var storyElementCount = 0
        var semanticFailure: String?
        walk(root) { element in
            if element.name == "asset" {
                assetCount += 1
                guard let name = element.attribute(forName: "name")?.stringValue,
                      !name.isEmpty,
                      !MediaFilename.isContentAddressed(name) else {
                    semanticFailure = "Every asset needs a readable, non-content-addressed filename."
                    return
                }
            }
            if storyNames.contains(element.name ?? "") { storyElementCount += 1 }
            if element.name == "media-rep" {
                guard let raw = element.attribute(forName: "src")?.stringValue,
                      let url = URL(string: raw),
                      url.isFileURL else {
                    semanticFailure = "Every media representation must contain a file URL."
                    return
                }
            }
            if element.name == "adjust-volume" {
                guard let amount = element.attribute(forName: "amount")?.stringValue,
                      amount.hasSuffix("dB"),
                      Double(amount.dropLast(2))?.isFinite == true else {
                    semanticFailure = "Static audio gain must be a finite dB value."
                    return
                }
            }
            for attribute in element.attributes ?? [] {
                guard let name = attribute.name,
                      timeAttributes.contains(name),
                      shouldValidateAsTime(name: name, element: element) else { continue }
                guard let raw = attribute.stringValue,
                      let rational = RationalTime(raw),
                      rational.isReduced,
                      name != "frameDuration" || rational.numerator > 0,
                      name != "duration" || rational.numerator >= 0 else {
                    semanticFailure = "Every time value must be reduced and within the supported rational range."
                    return
                }
            }
        }
        if let semanticFailure {
            throw ExportError.xmlValidationFailed(
                version: version.rawValue,
                reason: semanticFailure
            )
        }
        return .init(
            version: version,
            schemaProfile: schemaProfile(for: version),
            assetCount: assetCount,
            storyElementCount: storyElementCount
        )
    }

    private static func shouldValidateAsTime(name: String, element: XMLElement) -> Bool {
        guard name == "value" else { return true }
        return element.name == "timept"
    }

    private static func walk(_ element: XMLElement, visit: (XMLElement) -> Void) {
        visit(element)
        for child in element.children ?? [] {
            if let child = child as? XMLElement { walk(child, visit: visit) }
        }
    }

    private struct RationalTime {
        let numerator: Int64
        let denominator: Int64
        var isReduced: Bool { numerator == 0 || greatestCommonDivisor(numerator.magnitude, UInt64(denominator)) == 1 }

        init?(_ raw: String) {
            guard raw.hasSuffix("s") else { return nil }
            let value = String(raw.dropLast())
            let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
            if pieces.count == 1, let numerator = Int64(pieces[0]) {
                self.numerator = numerator
                denominator = 1
            } else if pieces.count == 2,
                      let numerator = Int64(pieces[0]),
                      let denominator = Int64(pieces[1]),
                      denominator > 0,
                      denominator <= Int64(Int32.max) {
                self.numerator = numerator
                self.denominator = denominator
            } else {
                return nil
            }
        }

        private func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            var x = lhs
            var y = rhs
            while y != 0 {
                let remainder = x % y
                x = y
                y = remainder
            }
            return max(1, x)
        }
    }

    private static func validationReason(_ error: Error) -> String {
        let reason = (error as NSError).localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "The document does not match the selected schema." : reason
    }

    private static let officialSchemaSHA256: [FCPXMLVersion: String] = [
        .v1_10: "32cbad28022f9a2033acdc25d0583b16d2e12745dc5efe4fa8f16e27aa59ff53",
        .v1_11: "fc85a0b4e56f28d63774f2e333301800db19c160b55cc118b55c4fe199f633be",
        .v1_12: "bbe42905cf88ec896dde170c5b3bd86e153a05436f17a22740d09dee2f32b1b1",
        .v1_13: "5afbc7ca1001bbc2190fb3b21d4d440ce061d94f5a5f583074e982b4745cd04d",
        .v1_14: "33bb44530790be145d87ed2d5c347166aab945c90f1cfbc03c8be545aaf73cb5",
    ]

    private static func schemaData(for version: FCPXMLVersion) throws -> Data {
        let filename = "FCPXMLv" + version.rawValue.replacingOccurrences(of: ".", with: "_")
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "dtd",
            subdirectory: "FCPXML DTDs"
        ) else {
            throw ExportError.xmlValidationFailed(
                version: version.rawValue,
                reason: "The official Apple FCPXML DTD is missing from the app."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ExportError.xmlValidationFailed(
                version: version.rawValue,
                reason: "The official Apple FCPXML DTD could not be read: \(error.localizedDescription)"
            )
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == officialSchemaSHA256[version] else {
            throw ExportError.xmlValidationFailed(
                version: version.rawValue,
                reason: "The bundled Apple FCPXML DTD failed its integrity check."
            )
        }
        return data
    }
}
