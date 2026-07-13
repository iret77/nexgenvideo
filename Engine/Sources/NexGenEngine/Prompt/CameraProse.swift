import Foundation

/// Project a shot's STRUCTURED camera + framing into prompt prose, so the camera in a frame prompt is
/// derived from the shot spec rather than reconstructed (or forgotten) by the agent. Port of the camera
/// projection in `frames/generate.py` — the piece that was missing on the Swift side (#166): the
/// `CameraSetup` types were ported but never compiled into the prompt.
extension CameraSetup {
    /// The deterministic camera line: "`<height>` camera height, `<angle>`, `<lens>` lens feel[, `<note>`]".
    /// Enum raw values carry underscores (`three_quarter_left`); angle is spaced for prose.
    public func promptProse() -> String {
        var parts = [
            "\(height.rawValue) camera height",
            angle.rawValue.replacingOccurrences(of: "_", with: " "),
            "\(lensHint.rawValue) lens feel",
        ]
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty { parts.append(trimmedNote) }
        return parts.joined(separator: ", ")
    }
}

extension Framing {
    /// The composition line for a frame prompt, e.g. "ms framing". Port of `frames/generate.py`'s
    /// `composition = f"{framing.value} framing"`.
    public var compositionProse: String { "\(rawValue) framing" }
}
