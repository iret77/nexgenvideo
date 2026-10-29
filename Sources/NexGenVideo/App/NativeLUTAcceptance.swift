import AppKit
import NexGenEngine

@MainActor
enum NativeLUTAcceptance {
    static func run(editor: EditorViewModel, clipID: String, directory: URL, window: NSWindow,
                    driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        guard let home = editor.workingRoot, editor.selectedClipIds == [clipID],
              (editor.clipFor(id: clipID)?.effects ?? []).isEmpty else { throw GateBlocked("LUT acceptance needs the actual ungraded clip.") }
        let baseline = editor.timeline
        let original = try await PostproductionControlsAcceptance.readablePreview(editor)
        let first = directory.appendingPathComponent("first-look/Look.cube")
        let second = directory.appendingPathComponent("second-look/Look.cube")
        let invalid = directory.appendingPathComponent("Invalid.cube")
        let firstBytes = cube(inverted: true), secondBytes = cube(inverted: false)
        for (url, bytes) in [(first, firstBytes), (second, secondBytes), (invalid, Data("Not a LUT".utf8))] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let firstPath = "resources/luts/" + FileDigest.sha256(of: firstBytes) + ".cube"
        let secondPath = "resources/luts/" + FileDigest.sha256(of: secondBytes) + ".cube"
        func effect() -> Effect? { editor.clipFor(id: clipID)?.effects?.first(where: { $0.type == "color.lut" }) }
        func choose(_ url: URL, expectedPath: String) async throws {
            try await driver.chooseFile(url, in: window, trigger: "inspector.lut.choose")
            try await driver.wait("native portable LUT binding") {
                effect()?.params["path"]?.string == expectedPath && driver.state("inspector.lut.choose", in: window) == true
            }
            guard effect()?.params["name"]?.string == "Look.cube",
                  driver.text("inspector.lut.name", in: window) == "Look.cube",
                  (driver.text("inspector.lut.error", in: window) ?? "").isEmpty else {
                throw GateBlocked("The native LUT chooser did not retain its readable filename and success state.")
            }
        }
        try await driver.click("inspector.tab.Adjust", in: window, enabled: false)
        try await driver.wait("LUT Adjust inspector") { driver.state("inspector.tab.Adjust", in: window) == true }
        if driver.text("inspector.section.LUTs", in: window) != "expanded" {
            try await driver.click("inspector.section.LUTs", in: window)
        }
        try await driver.chooseFile(nil, in: window, trigger: "inspector.lut.choose")
        guard editor.timeline == baseline else { throw GateBlocked("Cancelling the LUT chooser changed the film.") }
        try await driver.chooseFile(invalid, in: window, trigger: "inspector.lut.choose")
        let invalidError = LUTStoreError.invalid(invalid.lastPathComponent).errorDescription
        try await driver.wait("invalid LUT visible error") {
            driver.text("inspector.lut.error", in: window) == invalidError && driver.state("inspector.lut.choose", in: window) == true
        }
        let observedInvalidError = driver.text("inspector.lut.error", in: window) ?? ""
        guard editor.timeline == baseline else { throw GateBlocked("An invalid LUT changed the film.") }
        try driver.capture("lut-invalid", target: window)
        try await choose(first, expectedPath: firstPath)
        let inverted = try await PostproductionControlsAcceptance.changedPreview(editor, from: original)
        try driver.capture("lut-inverted", target: window)
        try await driver.fill("inspector.lut.intensity", value: "50", in: window, requireFocusExit: true)
        try await driver.wait("native LUT intensity") { effect()?.params["intensity"]?.value == 0.5 }
        let half = try await PostproductionControlsAcceptance.changedPreview(editor, from: inverted)
        guard PostproductionControlsAcceptance.difference(half, original) > 2 else {
            throw GateBlocked("LUT intensity did not produce a distinct intermediate composition.")
        }
        let halfTimeline = editor.timeline
        try driver.capture("lut-intensity", target: window)
        try await driver.click("inspector.adjust.bypass.LUTs", in: window)
        try await driver.wait("native LUT bypass") { effect()?.enabled == false }
        try await PostproductionControlsAcceptance.matchingPreview(editor, expected: original)
        try await driver.click("inspector.adjust.bypass.LUTs", in: window)
        try await driver.wait("native LUT restore") { editor.timeline == halfTimeline }
        try await PostproductionControlsAcceptance.matchingPreview(editor, expected: half)
        try await driver.click("inspector.reset.Reset luts", in: window)
        try await driver.wait("native LUT reset") { editor.timeline == baseline }
        try await PostproductionControlsAcceptance.matchingPreview(editor, expected: original)
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("native LUT reset undo") { editor.timeline == halfTimeline }
        try await PostproductionControlsAcceptance.matchingPreview(editor, expected: half)
        try await choose(second, expectedPath: secondPath)
        let replacementTimeline = editor.timeline
        let replacement = try await PostproductionControlsAcceptance.changedPreview(editor, from: original)
        guard PostproductionControlsAcceptance.difference(replacement, half) > 2 else {
            throw GateBlocked("The replacement LUT did not change the rendered composition.")
        }
        guard firstPath != secondPath,
              try Data(contentsOf: home.appendingPathComponent(firstPath)) == firstBytes,
              try Data(contentsOf: home.appendingPathComponent(secondPath)) == secondBytes else {
            throw GateBlocked("Loading a second same-named LUT replaced the original project's LUT bytes.")
        }
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("native LUT replacement undo") { editor.timeline == halfTimeline }
        try await PostproductionControlsAcceptance.matchingPreview(editor, expected: half)
        try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
        try await driver.wait("native LUT replacement redo") { editor.timeline == replacementTimeline }
        try await PostproductionControlsAcceptance.matchingPreview(editor, expected: replacement)
        try await driver.fill("inspector.lut.intensity", value: "100", in: window, requireFocusExit: true)
        try await driver.wait("native final LUT strength") { effect()?.params["intensity"]?.value == 1 }
        _ = try await PostproductionControlsAcceptance.changedPreview(editor, from: replacement)
        try driver.capture("lut-portable-replacement", target: window)
        let evidence: [String: Any] = ["firstPath": firstPath, "secondPath": secondPath,
            "firstSHA256": FileDigest.sha256(of: firstBytes), "secondSHA256": FileDigest.sha256(of: secondBytes),
            "cancelPreservedTimeline": true, "invalidFileVisible": true,
            "invalidError": observedInvalidError,
            "sameFilenameBytesPreserved": true,
            "intensityBypassReset": true, "nativeUndoRedo": true, "readableName": "Look.cube",
            "playerItemCompositionVerified": true, "selectedIntensity": 1]
        try driver.record("native portable LUTs", fields: evidence)
        try await driver.click("inspector.section.LUTs", in: window)
        try await driver.click("inspector.tab.Video", in: window, enabled: false)
        try await driver.wait("LUT return to Video inspector") { driver.state("inspector.tab.Video", in: window) == true }
        return evidence
    }

    static func requireSaved(_ evidence: [String: Any], in home: URL) throws {
        guard let path = evidence["secondPath"] as? String, let expected = evidence["secondSHA256"] as? String,
              ProjectEffectResources.isPortable(path), try FileDigest.sha256(of: home.appendingPathComponent(path)) == expected else {
            throw GateBlocked("The exact native LUT did not survive project Save and reopen.")
        }
    }

    private static func cube(inverted: Bool) -> Data {
        let rows = (0..<8).map { index in
            let rgb = [index & 1, (index >> 1) & 1, (index >> 2) & 1]
            return (inverted ? rgb.map { 1 - $0 } : [0, rgb[1], rgb[2]]).map(String.init).joined(separator: " ")
        }
        return Data(("LUT_3D_SIZE 2\n" + rows.joined(separator: "\n") + "\n").utf8)
    }
}
