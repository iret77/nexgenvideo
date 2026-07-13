import Foundation
import NexGenEngine

/// Frame-manifest sanity checks — port of `sanity/checks/{frame_ratio,frame_size,
/// builder_bypass}.py`. All read `frames/manifest.json` (the `FramesManifest`) via
/// `ctx.extra["data_root"]` and degrade to no findings when it's absent. Frame paths
/// are resolved relative to the data root; pixel dimensions come from ImageIO
/// (`FrameRasterizer.pixelSize`), not the manifest. The Python `frame_size` and the
/// identity-anchor planner traverse a non-existent top-level `frames` list (dead
/// against a real manifest) — this ports the INTENDED `shots[].frames[]` traversal.
extension MusicvideoChecks {
    /// FRAME_RATIO_MISMATCH / BRIEF_ASPECT_UNRESOLVED — each frame PNG's actual pixel
    /// aspect vs the brief's target aspect (2% tolerance).
    public static let frameRatioCheck: SanityCheck = { ctx in
        guard let brief = ctx.brief else { return [] }
        let target: Double
        do {
            let semantic = try Aspect.resolveBriefAspect(
                aspectRatio: brief.aspectRatio.rawValue, aspectRatioOther: brief.aspectRatioOther)
            guard let f = Aspect.toFloat[semantic] else { return [] }  // unknown semantic → silent, matching Python
            target = f
        } catch let e as Aspect.Unresolvable {
            return [Finding(level: .error, code: "BRIEF_ASPECT_UNRESOLVED", shotId: nil,
                message: "brief.aspect_ratio can't be resolved to a concrete W:H: \(e.message). "
                    + "Render/sheet generation would silently fall back to 16:9.")]
        } catch { return [] }

        guard let root = ctx.extra?["data_root"],
              let manifest = try? loadFramesManifest(dataRoot: URL(fileURLWithPath: root)) else { return [] }
        let dataRoot = URL(fileURLWithPath: root)
        let tolerance = 0.02
        var out: [Finding] = []
        for sf in manifest.shots {
            for frame in sf.frames where !frame.path.isEmpty {
                guard let size = FrameRasterizer.pixelSize(of: dataRoot.appendingPathComponent(frame.path)),
                      size.height > 0 else { continue }
                let actual = Double(size.width) / Double(size.height)
                if max(actual / target, target / actual) > 1 + tolerance {
                    out.append(Finding(level: .error, code: "FRAME_RATIO_MISMATCH", shotId: sf.shotId,
                        message: "frame \(frame.path) (\(frame.role)) is \(size.width)x\(size.height) → aspect "
                            + "\(String(format: "%.3f", actual)), brief wants \(String(format: "%.3f", target)) "
                            + "(\(brief.aspectRatio.rawValue)). Regenerate the sheet or crop to aspect."))
                }
            }
        }
        return out
    }

    /// FRAME_TOO_SMALL — each frame's short edge must be ≥ 1024px (identity-drift floor).
    public static let frameSizeCheck: SanityCheck = { ctx in
        guard let root = ctx.extra?["data_root"],
              let manifest = try? loadFramesManifest(dataRoot: URL(fileURLWithPath: root)) else { return [] }
        let dataRoot = URL(fileURLWithPath: root)
        var out: [Finding] = []
        for sf in manifest.shots {
            for frame in sf.frames where !frame.path.isEmpty {
                guard let size = FrameRasterizer.pixelSize(of: dataRoot.appendingPathComponent(frame.path)) else { continue }
                let shortEdge = min(size.width, size.height)
                if shortEdge < 1024 {
                    out.append(Finding(level: .warn, code: "FRAME_TOO_SMALL", shotId: sf.shotId,
                        message: "frame \(frame.path) short edge \(shortEdge)px < 1024px Seedance recommendation. "
                            + "Low resolution amplifies identity drift in image-to-video."))
                }
            }
        }
        return out
    }

    /// BUILDER_BYPASS_DETECTED — a frame with an empty `provider_prompt` was generated
    /// outside the prompt builder (slop-strip / positive framing / indexed refs /
    /// lighting mandate all skipped). Reference-mode shots are exempt (they legitimately
    /// carry no frame — the provider consumes bible sheets directly).
    public static let builderBypassCheck: SanityCheck = { ctx in
        guard let root = ctx.extra?["data_root"],
              let manifest = try? loadFramesManifest(dataRoot: URL(fileURLWithPath: root)) else { return [] }
        let referenceShots = Set(ctx.shotlist.shots.filter { $0.seedanceInputMode == .reference }.map { $0.id })
        var out: [Finding] = []
        for sf in manifest.shots where !referenceShots.contains(sf.shotId) {
            for frame in sf.frames where frame.providerPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Finding(level: .warn, code: "BUILDER_BYPASS_DETECTED", shotId: sf.shotId,
                    message: "frame \(sf.shotId)-\(frame.role): provider_prompt is empty — the frame wasn't generated "
                        + "via the prompt builder (slop-strip, positive framing, indexed refs, lighting mandate skipped)."))
            }
        }
        return out
    }
}
