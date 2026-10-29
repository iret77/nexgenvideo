import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum PostproductionControlsAcceptance {
    static func run(editor: EditorViewModel, clipID: String, window: NSWindow,
                    driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let baseline = editor.timeline
        guard editor.selectedClipIds == [clipID], editor.activePreviewTab == .timeline,
              let selected = editor.clipFor(id: clipID), selected.contains(timelineFrame: editor.currentFrame),
              (selected.effects ?? []).isEmpty else { throw GateBlocked("Finishing needs a selected ungraded clip at its actual playhead.") }
        let ungraded = try await readablePreview(editor)
        var verified: [String] = []
        func clip() -> Clip? { editor.clipFor(id: clipID) }
        func undo(_ label: String) async throws {
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("undo " + label) { editor.timeline == baseline }
            try await matchingPreview(editor, expected: ungraded)
            verified.append(label)
        }
        func section(_ name: String, expanded: Bool) async throws {
            let id = "inspector.section." + name
            let state = expanded ? "expanded" : "collapsed"
            if driver.text(id, in: window) != state { try await driver.click(id, in: window) }
            try await driver.wait("section " + name) { driver.text(id, in: window) == state }
        }
        let transformChecks: [(String, String, (Clip) -> Bool)] = [
            ("Position X", "32", { (c: Clip) in abs(c.transform.centerX - 0.6) < 0.00001 }),
            ("Position Y", "18", { (c: Clip) in abs(c.transform.centerY - 0.6) < 0.00001 }),
            ("Scale", "80", { (c: Clip) in c.transform.width == 0.8 && c.transform.height == 0.8 }),
            ("Rotation", "15", { (c: Clip) in c.transform.rotation == 15 }),
            ("Opacity", "75", { (c: Clip) in c.opacity == 0.75 }),
            ("Speed", "2.00", { (c: Clip) in c.speed == 2 && c.durationFrames == 45 })
        ]
        for (field, value, accepts) in transformChecks {
            try await driver.fill("inspector.value." + field, value: value, in: window, requireFocusExit: true)
            try await driver.wait("native " + field) { clip().map(accepts) == true }
            try await undo(field)
        }
        for (id, horizontal) in [("arrow.left.and.right", true), ("arrow.up.and.down", false)] {
            try await driver.click("inspector.transform." + id, in: window)
            try await driver.wait("native flip " + id) {
                horizontal ? clip()?.transform.flipHorizontal == true : clip()?.transform.flipVertical == true
            }
            try await undo("flip " + id)
        }
        try driver.capture("finishing-transform", target: window)
        try await driver.click("inspector.tab.Adjust", in: window, enabled: false)
        try await driver.wait("adjust inspector") { driver.state("inspector.tab.Adjust", in: window) == true }
        let controls: [(String, [(String, String, String, Double)])] = [
            ("Basic Correction", [
                ("color.exposure", "ev", "0.50", 0.5), ("color.contrast", "amount", "1.20", 1.2),
                ("color.highlightsShadows", "highlights", "-0.30", -0.3), ("color.highlightsShadows", "shadows", "0.30", 0.3),
                ("color.blacksWhites", "blacks", "0.20", 0.2), ("color.blacksWhites", "whites", "-0.20", -0.2),
                ("color.temperature", "temperature", "7500", 7500), ("color.temperature", "tint", "20", 20),
                ("color.vibrance", "amount", "0.30", 0.3), ("color.saturation", "amount", "0.70", 0.7)]),
            ("Detail", [
                ("blur.sharpen", "amount", "0.40", 0.4), ("blur.noiseReduction", "amount", "0.40", 0.4),
                ("blur.noiseReduction", "chroma", "0.40", 0.4), ("blur.noiseReduction", "detail", "0.30", 0.3),
                ("detail.clarity", "clarity", "0.20", 0.2), ("detail.clarity", "dehaze", "0.20", 0.2)]),
            ("Blur", [("blur.gaussian", "radius", "10", 10)]),
            ("Motion Blur", [("blur.motion", "radius", "10", 10), ("blur.motion", "angle", "30", 30)]),
            ("Vignette", [("stylize.vignette", "amount", "0.30", 0.3), ("stylize.vignette", "midpoint", "0.30", 0.3),
                          ("stylize.vignette", "roundness", "0.20", 0.2), ("stylize.vignette", "feather", "0.30", 0.3)]),
            ("Film Grain", [("stylize.grain", "amount", "0.20", 0.2), ("stylize.grain", "size", "2.00", 2)]),
            ("Glow", [("stylize.glow", "intensity", "0.30", 0.3), ("stylize.glow", "radius", "30", 30),
                      ("stylize.glow", "threshold", "0.40", 0.4), ("stylize.glow", "warmth", "0.20", 0.2)]),
            ("Chroma Key", [("key.chroma", "keyHue", "0.20", 0.2), ("key.chroma", "tolerance", "0.30", 0.3),
                            ("key.chroma", "softness", "0.30", 0.3), ("key.chroma", "spill", "0.30", 0.3)])
        ]
        for (name, parameters) in controls {
            if name == "Detail" { try await section("Effects", expanded: true) }
            try await section(name, expanded: true)
            for (effect, parameter, input, expected) in parameters {
                guard let spec = EffectRegistry.descriptor(id: effect)?.params.first(where: { $0.key == parameter }),
                      spec.range.contains(expected), spec.defaultValue != expected,
                      String(format: spec.range.upperBound - spec.range.lowerBound <= 20 ? "%.2f" : "%.0f", expected) == input else {
                    throw GateBlocked("The acceptance value no longer exercises the declared parameter: " + effect + "." + parameter)
                }
                let id = "inspector.adjust.value." + effect + "." + parameter
                try await driver.fill(id, value: input, in: window, requireFocusExit: true)
                try await driver.wait("native effect " + effect + "." + parameter) {
                    clip()?.effects?.first(where: { $0.type == effect })?.params[parameter]?.resolved(at: 0, default: .nan) == expected
                }
                try await undo(effect + "." + parameter)
            }
            try driver.capture("finishing-" + name.lowercased().replacingOccurrences(of: " ", with: "-"), target: window)
            try await section(name, expanded: false)
        }
        try await section("Effects", expanded: false)
        try await section("Basic Correction", expanded: true)
        try await matchingPreview(editor, expected: ungraded)
        try await driver.fill("inspector.adjust.value.color.exposure.ev", value: "1.00", in: window, requireFocusExit: true)
        try await driver.wait("exposure change") { clip()?.effects?.first?.params["ev"]?.value == 1 }
        let exposed = try await changedPreview(editor, from: ungraded)
        try await driver.click("inspector.adjust.bypass.Basic Correction", in: window)
        try await driver.wait("actual correction bypass") { clip()?.effects?.allSatisfy { !$0.enabled } == true }
        try await matchingPreview(editor, expected: ungraded)
        try await driver.click("inspector.adjust.bypass.Basic Correction", in: window)
        try await driver.wait("actual correction restored") { clip()?.effects?.allSatisfy(\.enabled) == true }
        try await matchingPreview(editor, expected: exposed)
        try await driver.click("inspector.reset.Reset basic correction", in: window)
        try await driver.wait("actual correction reset") { editor.timeline == baseline }
        try await matchingPreview(editor, expected: ungraded)
        verified.append("Basic Correction bypass/reset and rendered exposure")
        try await section("Basic Correction", expanded: false)
        try await section("Color Wheels", expanded: true)
        for (name, prefix) in [("Lift", "lift"), ("Gamma", "gamma"), ("Gain", "gain")] {
            let id = "inspector.wheel." + name
            try await driver.drag(id, from: .init(x: 0.5, y: 0.5), to: .init(x: 0.7, y: 0.4), in: window)
            try await driver.wait("native " + name + " color") {
                let value = clip()?.effects?.first(where: { $0.type == "color.wheels" })?.params[prefix + "_x"]?.value ?? 0
                return value > 0.25 && value < 0.55
            }
            _ = try await changedPreview(editor, from: ungraded)
            try driver.capture("finishing-wheel-" + prefix, target: window)
            try await undo(name + " color and rendered composition")
            try await driver.click("inspector.wheel.level." + name, in: window, fraction: .init(x: 0.8, y: 0.5))
            let expected = prefix == "lift" ? 0.3 : prefix == "gamma" ? 1.7 : 1.3
            try await driver.wait("native " + name + " level") {
                let value = clip()?.effects?.first(where: { $0.type == "color.wheels" })?.params[prefix + "_m"]?.value ?? .nan
                return abs(value - expected) < 0.03
            }
            try await undo(name + " level")
        }
        try await section("Color Wheels", expanded: false)
        for (sectionName, prefix, channels, effect) in [
            ("Curves", "curve", ["Y", "R", "G", "B"], "color.curves"),
            ("Hue Curves", "hue-curve", ["Hue", "Sat", "Luma"], "color.hueCurves")
        ] {
            try await section(sectionName, expanded: true)
            for channel in channels {
                try await driver.segment("inspector." + prefix + ".channel", title: channel, titles: channels, in: window)
                try await driver.drag("inspector." + prefix + ".canvas", from: .init(x: 0.5, y: 0.5),
                                      to: .init(x: 0.5, y: 0.25), in: window)
                try await driver.wait("native " + sectionName + " " + channel) {
                    guard let effects = clip()?.effects else { return false }
                    if effect == "color.curves" {
                        guard let json = effects.first(where: { $0.type == effect })?.params["curve"]?.string,
                              let curve = GradeCurve(json: json) else { return false }
                        let values = ["Y": curve.master, "R": curve.red, "G": curve.green, "B": curve.blue]
                        return values.allSatisfy { $0.key == channel ? !$0.value.isEmpty && $0.value != GradeCurve.identityPoints : $0.value.isEmpty }
                    }
                    let curves = HueCurves.read(from: effects)
                    return HueCurves.Channel.allCases.allSatisfy {
                        $0.rawValue == channel ? !HueCurves.isNeutral(curves.points($0)) : curves.points($0).isEmpty
                    }
                }
                try driver.capture("finishing-" + prefix + "-" + channel, target: window)
                try await undo(sectionName + " " + channel)
            }
            try await section(sectionName, expanded: false)
        }
        try await driver.click("inspector.tab.Video", in: window, enabled: false)
        try await driver.wait("return to video inspector") { driver.state("inspector.tab.Video", in: window) == true && editor.timeline == baseline }
        try driver.record("native finishing controls", fields: ["verified": verified,
            "playerItemCompositionExposureAndWheels": true, "baselineRestored": true])
        return ["controls": verified, "playerItemCompositionExposureAndWheels": true, "baselineRestored": true]
    }

    static func readablePreview(_ editor: EditorViewModel) async throws -> [UInt8] {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var lastError: Error?
        while ProcessInfo.processInfo.systemUptime < deadline {
            do { return try await previewPixels(editor) } catch { lastError = error }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw GateBlocked("The player composition is not readable. " + (lastError?.localizedDescription ?? ""))
    }

    private static func previewPixels(_ editor: EditorViewModel) async throws -> [UInt8] {
        guard let item = editor.videoEngine?.player.currentItem else { throw GateBlocked("The actual timeline preview has no player item.") }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(value: CMTimeValue(editor.currentFrame), timescale: CMTimeScale(editor.timeline.fps))
        let image = try await generator.image(at: time).image
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw GateBlocked("The actual timeline preview has no readable pixels.")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func difference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        return zip(lhs, rhs).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(lhs.count)
    }

    static func changedPreview(_ editor: EditorViewModel, from original: [UInt8]) async throws -> [UInt8] {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var lastError: Error?
        while ProcessInfo.processInfo.systemUptime < deadline {
            do {
                let pixels = try await previewPixels(editor)
                if difference(pixels, original) > 2 { return pixels }
            } catch { lastError = error }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw GateBlocked("The player composition did not render the finishing edit. " + (lastError?.localizedDescription ?? ""))
    }

    static func matchingPreview(_ editor: EditorViewModel, expected: [UInt8]) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var lastError: Error?
        while ProcessInfo.processInfo.systemUptime < deadline {
            do {
                if difference(try await previewPixels(editor), expected) < 0.1 { return }
            } catch { lastError = error }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw GateBlocked("The player composition did not restore the previous grade. " + (lastError?.localizedDescription ?? ""))
    }
}
