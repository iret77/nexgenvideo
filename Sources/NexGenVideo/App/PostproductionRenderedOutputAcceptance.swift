import AppKit
import NexGenEngine

@MainActor
enum PostproductionRenderedOutputAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "post-rendered-\(Int(scale * 100))"
        let directory = output.appendingPathComponent(name, isDirectory: true)
        let package = directory.appendingPathComponent("Rendered adjustments.ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        var empty = Timeline()
        empty.width = 320; empty.height = 180; empty.fps = 30; empty.settingsConfigured = true
        try PlanningWriterIO.json(empty).write(to: package.appendingPathComponent(Project.timelineFilename))
        try PlanningWriterIO.json(MediaManifest()).write(to: package.appendingPathComponent(Project.manifestFilename))
        try PlanningWriterIO.json(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let sources = try PostproductionRenderedEvidence.sources(directory: directory)
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers()
        defer { document.close() }
        guard let window = document.windowControllers.first?.window else { throw failed("The actual project window is missing.") }
        document.showWindows(); window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu = MainMenuBuilder.buildMenu(); NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        do {
            try await driver.wait("measured rendered-adjustment workspace") {
                window.contentView?.bounds.size == AppTheme.Window.projectMin && window.isKeyWindow
                    && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
            }
            try await NativeEditingOwnerAcceptance.workspace(.media, editor: editor, window: window, driver: driver)
            var assets: [MediaAsset] = []
            for source in sources {
                try await driver.chooseFile(source, in: window, trigger: "media.action.Import")
                try await driver.wait("native adjustment source import") { editor.mediaAssets.count == assets.count + 1 }
                guard let asset = editor.mediaAssets.first(where: { $0.userFacingFilename == source.lastPathComponent }),
                      let imported = editor.mediaResolver.resolveURL(for: asset.id), asset.type == .image,
                      editor.timeline.tracks.isEmpty,
                      try FileDigest.sha256(of: imported) == FileDigest.sha256(of: source) else {
                    throw failed("Native image import changed the source or inserted a clip.")
                }
                assets.append(asset)
            }
            try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
            var clips: [Clip] = []
            for (index, asset) in assets.enumerated() {
                try await driver.reveal("media.asset." + asset.id, in: window)
                try await driver.click("media.asset." + asset.id, in: window)
                try await driver.wait("actual source destination") { driver.text("source.target." + asset.id, in: window) != nil }
                try await driver.picker("source.target." + asset.id, title: "New Track", expected: "", in: window)
                try await driver.reveal("source.overwrite." + asset.id, in: window)
                try await driver.click("source.overwrite." + asset.id, in: window)
                try await driver.wait("native adjustment image layer") { editor.timeline.tracks.count == index + 1 }
                guard let track = editor.timeline.tracks.first(where: { $0.clips.first?.mediaRef == asset.id }),
                      track.clips.count == 1, let clip = track.clips.first, clip.startFrame == 0,
                      clip.durationFrames == 150, clip.trimStartFrame == 0,
                      clips.allSatisfy({ editor.clipFor(id: $0.id) == $0 }) else { throw failed("The actual image layer changed an existing clip.") }
                clips.append(clip)
            }
            guard let foreground = clips.first, editor.timeline.tracks.flatMap(\.clips).map(\.id) == clips.map(\.id) else {
                throw failed("The native foreground must be above the blue background.")
            }
            try GenericNLEAcceptance.pointerOnRuler(frame: 0, window: window, driver: driver)
            try GenericNLEAcceptance.pointerOnClip(foreground, editor: editor, window: window, driver: driver)
            try await driver.wait("actual foreground selection") {
                editor.currentFrame == 0 && editor.activePreviewTab == .timeline && editor.selectedClipIds == [foreground.id]
            }
            let baseline = editor.timeline
            guard (foreground.effects ?? []).isEmpty else { throw failed("The fixture foreground is already graded.") }
            let original = try await PostproductionRenderedEvidence.capture(editor: editor, baseline: nil)
            try PostproductionRenderedEvidence.requireForeground(original, directory: directory)
            let originalFiles = try PostproductionRenderedEvidence.retain(original, timeline: baseline, label: "baseline", directory: directory)
            let sourceFiles = try Dictionary(uniqueKeysWithValues: sources.flatMap { url in
                [url, url.deletingPathExtension().appendingPathExtension("rgba")]
            }.map { ($0.lastPathComponent, try FileDigest.sha256(of: $0)) })
            try driver.record("rendered adjustments begin", fields: ["clipID": foreground.id, "assetIDs": assets.map(\.id),
                "files": originalFiles, "sources": sourceFiles, "frame": editor.currentFrame, "width": original.width, "height": original.height])
            try driver.capture("baseline", target: window)
            try await driver.click("inspector.tab.Adjust", in: window, enabled: false)
            try await driver.wait("actual adjustment inspector") { driver.state("inspector.tab.Adjust", in: window) == true }
            func section(_ title: String, _ expanded: Bool) async throws {
                let id = "inspector.section." + title, state = expanded ? "expanded" : "collapsed"
                if driver.text(id, in: window) != state { try await driver.click(id, in: window) }
                try await driver.wait("visible adjustment section") { driver.text(id, in: window) == state }
            }
            var cases: [String] = []
            func verify(_ key: String, effect: String) async throws {
                let changed = editor.timeline
                guard changed != baseline, let actual = editor.clipFor(id: foreground.id), actual.effects?.count == 1,
                      actual.effects?.first?.type == effect, actual.effects?.first?.enabled == true else {
                    throw failed("The native edit did not produce the single expected effect: " + key)
                }
                let rendered = try await PostproductionRenderedEvidence.capture(editor: editor, baseline: original)
                if effect == "key.chroma" { try PostproductionRenderedEvidence.requireChroma(rendered, directory: directory) }
                let changedFiles = try PostproductionRenderedEvidence.retain(rendered, timeline: changed, label: key, directory: directory)
                try driver.capture(key, target: window)
                try driver.record("rendered adjustment before undo", fields: ["case": key, "effect": effect, "files": changedFiles,
                    "frame": editor.currentFrame, "meanAbsoluteDifference": PostproductionControlsAcceptance.difference(original.pixels, rendered.pixels)])
                try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
                try await driver.wait("native rendered adjustment undo") { editor.timeline == baseline }
                let restored = try await PostproductionRenderedEvidence.capture(editor: editor, matching: original)
                let undoFiles = try PostproductionRenderedEvidence.retain(restored, timeline: editor.timeline, label: key + "-undo", directory: directory)
                try driver.record("rendered adjustment restored", fields: ["case": key, "files": undoFiles, "frame": editor.currentFrame])
                cases.append(key)
            }
            let families = [
                ("Basic Correction", "color.exposure", "ev", "1.00", 1.0),
                ("Basic Correction", "color.contrast", "amount", "1.50", 1.5),
                ("Basic Correction", "color.highlightsShadows", "shadows", "0.60", 0.6),
                ("Basic Correction", "color.blacksWhites", "blacks", "0.40", 0.4),
                ("Basic Correction", "color.temperature", "temperature", "8500", 8500.0),
                ("Basic Correction", "color.vibrance", "amount", "0.80", 0.8),
                ("Basic Correction", "color.saturation", "amount", "0.20", 0.2),
                ("Detail", "blur.sharpen", "amount", "0.80", 0.8),
                ("Detail", "blur.noiseReduction", "amount", "1.00", 1.0),
                ("Detail", "detail.clarity", "clarity", "0.80", 0.8),
                ("Blur", "blur.gaussian", "radius", "10", 10.0),
                ("Motion Blur", "blur.motion", "radius", "10", 10.0),
                ("Vignette", "stylize.vignette", "amount", "0.70", 0.7),
                ("Film Grain", "stylize.grain", "amount", "0.60", 0.6),
                ("Glow", "stylize.glow", "intensity", "0.80", 0.8),
                ("Chroma Key", "key.chroma", "tolerance", "0.30", 0.3)
            ]
            for (title, effect, parameter, input, expected) in families {
                guard let spec = EffectRegistry.descriptor(id: effect)?.params.first(where: { $0.key == parameter }),
                      spec.range.contains(expected), spec.defaultValue != expected else { throw failed("The adjustment input must change an existing supported parameter: " + effect) }
                if title != "Basic Correction" { try await section("Effects", true) }
                try await section(title, true)
                try await driver.fill("inspector.adjust.value." + effect + "." + parameter, value: input, in: window, requireFocusExit: true)
                try await driver.wait("actual rendered-effect binding") {
                    editor.clipFor(id: foreground.id)?.effects?.first?.params[parameter]?.resolved(at: 0, default: .nan) == expected
                }
                try await verify(effect, effect: effect)
                try await section(title, false)
            }
            try await section("Effects", false)
            try await section("Color Wheels", true)
            for (title, prefix) in [("Lift", "lift"), ("Gamma", "gamma"), ("Gain", "gain")] {
                try await driver.drag("inspector.wheel." + title, from: .init(x: 0.5, y: 0.5), to: .init(x: 0.7, y: 0.6), in: window)
                try await driver.wait("actual wheel binding") {
                    let params = editor.clipFor(id: foreground.id)?.effects?.first?.params ?? [:]
                    let x = params[prefix + "_x"]?.value ?? .nan, y = params[prefix + "_y"]?.value ?? .nan
                    return abs(x - 0.4) < 0.03 && abs(y - 0.2) < 0.03
                }
                try await verify("wheel-" + prefix, effect: "color.wheels")
                try await driver.click("inspector.wheel.level." + title, in: window, fraction: .init(x: 0.8, y: 0.5))
                let expected = prefix == "lift" ? 0.3 : prefix == "gamma" ? 1.7 : 1.3
                try await driver.wait("actual wheel level") {
                    let value = editor.clipFor(id: foreground.id)?.effects?.first?.params[prefix + "_m"]?.value ?? .nan
                    return abs(value - expected) < 0.03
                }
                try await verify("level-" + prefix, effect: "color.wheels")
            }
            try await section("Color Wheels", false)
            for (title, prefix, channels, effect) in [("Curves", "curve", ["Y", "R", "G", "B"], "color.curves"),
                                                      ("Hue Curves", "hue-curve", ["Hue", "Sat", "Luma"], "color.hueCurves")] {
                try await section(title, true)
                for channel in channels {
                    try await driver.segment("inspector." + prefix + ".channel", title: channel, titles: channels, in: window)
                    try await driver.drag("inspector." + prefix + ".canvas", from: .init(x: 0.5, y: 0.5), to: .init(x: 0.5, y: 0.75), in: window)
                    try await driver.wait("actual curve binding") { editor.clipFor(id: foreground.id)?.effects?.first?.type == effect }
                    try await verify(prefix + "-" + channel, effect: effect)
                }
                try await section(title, false)
            }
            try driver.record("rendered adjustments completed", fields: ["cases": cases, "baselineFiles": originalFiles])
            var result = driver.result()
            result.merge(["directory": name, "scale": scale, "viewport": [window.contentView!.bounds.width, window.contentView!.bounds.height],
                "effectiveScale": AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)),
                "backingScale": window.backingScaleFactor, "cases": cases]) { _, value in value }
            return result
        } catch { driver.failure(error); throw error }
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native rendered adjustments: " + message) }
}
