import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = [
        "clipIds", "fontName", "fontSize", "color", "centerX", "centerY", "textCase", "censorProfanity", "language",
        "subtitleMediaRef",
    ]

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        if args.keys.contains("subtitleMediaRef") {
            guard let mediaRef = args.string("subtitleMediaRef"), !mediaRef.isEmpty else {
                throw ToolError("add_captions: subtitleMediaRef must be a non-empty media asset id string.")
            }
            let combined = Set(args.keys).subtracting(["subtitleMediaRef"])
            guard combined.isEmpty else {
                throw ToolError(
                    "add_captions: subtitleMediaRef can't be combined with \(combined.sorted().joined(separator: ", "))."
                )
            }
            let asset = try asset(mediaRef, editor: editor)
            guard asset.type == .subtitle else {
                throw ToolError("add_captions: '\(mediaRef)' is \(asset.type.rawValue), not a caption file.")
            }
            do {
                let ids = try await editor.placeCaptions(fromSubtitleAssets: [asset])
                guard !ids.isEmpty else { throw ToolError("The caption file contains no cues.") }
                return .ok("Added \(ids.count) caption\(ids.count == 1 ? "" : "s") from '\(asset.userFacingFilename)'.")
            } catch let error as SubtitleFileParser.ParseError {
                throw ToolError("add_captions: \(error.localizedDescription)")
            }
        }

        let clipIds = (args["clipIds"] as? [Any])?.compactMap { $0 as? String } ?? []

        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        if let f = args.string("fontName") { style.fontName = f }
        if let s = args.double("fontSize") { style.fontSize = s }
        if let c = try parseColorHex(args.string("color"), path: "add_captions") { style.color = c }

        var locale: Locale?
        if let lang = args.string("language") {
            let candidate = Locale(identifier: lang)
            guard let match = Transcription.matchLocale(candidates: [candidate], supported: await Transcription.supportedLocales()) else {
                throw ToolError("add_captions: on-device transcription does not support language '\(lang)'.")
            }
            locale = match
        }

        var center = AppTheme.Caption.defaultCenter
        if let x = args.double("centerX") { center.x = CGFloat(x) }
        if let y = args.double("centerY") { center.y = CGFloat(y) }

        var textCase: EditorViewModel.CaptionCase = .auto
        if let raw = args.string("textCase") {
            guard let parsed = EditorViewModel.CaptionCase(rawValue: raw) else {
                throw ToolError("add_captions: textCase must be auto, upper, or lower (got \(raw))")
            }
            textCase = parsed
        }

        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: clipIds,
            autoDetect: clipIds.isEmpty,
            style: style,
            center: center,
            textCase: textCase,
            censorProfanity: args.bool("censorProfanity") ?? false,
            locale: locale
        )

        let ids = try await editor.generateCaptions(for: request)
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }
        return .ok("Added \(ids.count) caption\(ids.count == 1 ? "" : "s").")
    }
}
