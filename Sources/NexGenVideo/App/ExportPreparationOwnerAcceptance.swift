import AppKit
import NexGenEngine

@MainActor
enum ExportPreparationOwnerAcceptance {
    private typealias Support = ExportOwnerAcceptanceSupport

    @MainActor private final class Barrier {
        private(set) var entered = false
        private(set) var exited = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { value in
                if released { value.resume() } else { continuation = value }
            }
            exited = true
        }
        func release() {
            released = true
            let current = continuation; continuation = nil; current?.resume()
        }
    }

    @MainActor private final class KeyDelivery { var delivered = false }

    static func run(_ context: ExportOwnerAcceptanceSupport.Context) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested, PipelineDeliveryStore.nativeAcceptanceAfterAdoptionSnapshot == nil,
              let home = context.editor.workingRoot else { throw Support.failed("Preparation observation needs its exclusive native fixture.") }
        let editor = context.editor, driver = context.driver, window = context.window
        let originalTimeline = editor.timeline, originalManifest = editor.mediaManifest
        let identityURL = home.appendingPathComponent(ProjectPluginSettings.filename)
        let originalIdentity = try Data(contentsOf: identityURL)
        defer {
            PipelineDeliveryStore.nativeAcceptanceAfterAdoptionSnapshot = nil
            try? originalIdentity.write(to: identityURL, options: .atomic)
        }
        try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
        guard let picture = editor.clipFor(id: "picture") else { throw Support.failed("The actual picture fixture is missing.") }
        try GenericNLEAcceptance.pointerOnClip(picture, editor: editor, window: window, driver: driver)
        try await driver.wait("actual picture selected before Export") { editor.selectedClipIds == [picture.id] }
        try await Support.workspace(context)
        try await Support.select("export.codec", title: VideoCodec.h264.rawValue, in: window, driver: driver)
        try await Support.select("export.resolution", title: ExportResolution.matchTimeline.rawValue, in: window, driver: driver)
        try await Support.select("export.target", title: "Master", expected: "master", in: window, driver: driver)
        let panel = try await destinationPanel(context)
        let panelID = panel.windowNumber
        guard driver.state("export.start", in: window) == false else { throw Support.failed("Export remains enabled while choosing its destination.") }
        try driver.capture("destination-owner-disabled", target: window)
        try driver.capture("destination-first-panel", target: panel)
        guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu else { throw Support.failed("The native File menu is missing.") }
        fileMenu.update()
        guard let exportItem = fileMenu.items.first(where: { $0.action == #selector(EditorActions.showExport(_:)) }) else { throw Support.failed("The actual Export menu command is missing.") }
        let shortcut = exportItem.keyEquivalent, shortcutModifiers = exportItem.keyEquivalentModifierMask.rawValue
        let menuEnabled = exportItem.isEnabled
        guard shortcut == "e", shortcutModifiers == NSEvent.ModifierFlags.command.rawValue,
              !editor.showExportDialog, window.attachedSheet == nil else { throw Support.failed("The original export destination state or native shortcut changed.") }
        try driver.record("preparation destination before second Export", fields: ["panel": panelID,
            "keyEquivalent": shortcut, "modifiers": shortcutModifiers, "menuEnabled": menuEnabled])
        try await key(14, "e", modifiers: .command, window: panel, driver: driver)
        let runLoopCheckpoint = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume(returning: true) }
        }
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let actualStartEnabled = driver.state("export.start", in: window)
        let exportSheetPresented = editor.showExportDialog, ownerHasSheet = window.attachedSheet != nil
        let open = NSApp.windows.compactMap { $0 as? NSSavePanel }.filter(\.isVisible)
        guard runLoopCheckpoint, actualStartEnabled == false, !exportSheetPresented, !ownerHasSheet, open.count == 1, open[0] === panel else { throw Support.failed("The second native Export command created or replaced the destination panel.") }
        try driver.record("preparation destination single panel", fields: ["firstPanel": panelID,
            "afterSecondExportPanel": open[0].windowNumber, "count": open.count, "startEnabled": actualStartEnabled as Any? ?? NSNull(),
            "savePanelIDs": open.map(\.windowNumber), "showExportDialog": exportSheetPresented,
            "ownerHasAttachedSheet": ownerHasSheet, "runLoopCheckpoint": runLoopCheckpoint])
        try await key(53, "\u{1b}", window: panel, driver: driver)
        try await driver.wait("destination Cancel returns to Export") { !panel.isVisible && window.isKeyWindow && driver.state("export.start", in: window) == true }
        var observations: [[String: Any]] = []
        for variant in ["cancel", "timeline", "manifest", "metadata"] {
            try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
            guard let currentPicture = editor.clipFor(id: "picture") else { throw Support.failed("The actual picture disappeared.") }
            try GenericNLEAcceptance.pointerOnClip(currentPicture, editor: editor, window: window, driver: driver)
            try await driver.wait("actual picture selected for preparation") { editor.selectedClipIds == [currentPicture.id] }
            try await Support.workspace(context)
            let barrier = Barrier()
            PipelineDeliveryStore.nativeAcceptanceAfterAdoptionSnapshot = { await barrier.wait() }
            defer { barrier.release(); PipelineDeliveryStore.nativeAcceptanceAfterAdoptionSnapshot = nil }
            let destination = context.directory.appendingPathComponent("preparation-" + variant + ".mp4")
            let beforeJobs = Set(ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).map(\.id))
            let beforeFiles = try deliveryHashes(home)
            let before = try source(context, name: variant + "-before")
            try await driver.click("export.start", in: window)
            try await driver.saveFile(destination, in: window)
            try await driver.wait("actual prepared snapshot held before guards", seconds: 45) { barrier.entered && driver.text("export.preparing", in: window) == "Preparing export…" }
            guard !barrier.exited, driver.state("export.start", in: window) == false,
                  Set(ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).map(\.id)) == beforeJobs else { throw Support.failed("Preparation was not held before registration.") }
            try driver.capture("preparing-" + variant, target: window)
            try driver.record("preparation held " + variant, fields: ["preparing": driver.text("export.preparing", in: window) ?? "", "startEnabled": false, "jobIDs": beforeJobs.sorted()])
            if variant == "cancel" {
                try await driver.click("export.cancel-preparation", in: window)
                try await driver.wait("actual cancellation while owned preparation is held") {
                    driver.text("export.preparing", in: window) == "Cancelling export…"
                        && driver.state("export.cancel-preparation", in: window) == false
                }
                try driver.capture("cancelling-preparation", target: window)
            } else if variant == "timeline" {
                try await driver.reveal("inspector.transform.arrow.left.and.right", in: window)
                try await driver.click("inspector.transform.arrow.left.and.right", in: window)
                try await driver.wait("actual Inspector changes held export timeline") { editor.clipFor(id: "picture")?.transform.flipHorizontal == true }
            } else if variant == "manifest" {
                let incoming = context.directory.appendingPathComponent("Extra preparation sound.wav")
                try FullflowAcceptanceFixture.writeTone(to: incoming, duration: 3)
                try await AppNativeMenuAcceptance.choose(["File", "Import Media…"], in: window, driver: driver)
                try await driver.chooseFile(incoming, in: window, trigger: nil)
                try await driver.wait("actual native import changes held manifest") { editor.mediaManifest.entries.count == originalManifest.entries.count + 1 }
            } else {
                _ = try ProjectIdentity.regenerate(at: home)
                try originalIdentity.write(to: context.directory.appendingPathComponent("preparation-metadata-identity-before.json"))
                try Data(contentsOf: identityURL).write(to: context.directory.appendingPathComponent("preparation-metadata-identity-current.json"))
                try driver.record("controlled metadata source mutation", fields: ["nativeMetadataUI": false,
                    "originalSHA256": FileDigest.sha256(of: originalIdentity), "changedSHA256": try FileDigest.sha256(of: identityURL)])
            }
            let current = try source(context, name: variant + "-current")
            barrier.release()
            try await driver.wait("held preparation drains without publication", seconds: 45) {
                barrier.exited && driver.text("export.preparing", in: window) == nil && driver.state("export.start", in: window) == true
                    && (variant == "cancel" ? driver.text("export.result", in: window) == "Export cancelled."
                        : driver.text("export.error", in: window) == "The project changed while preparing the export. Prepare the export again from the current edit.")
            }
            guard !FileManager.default.fileExists(atPath: destination.path), try deliveryHashes(home) == beforeFiles,
                  Set(ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).map(\.id)) == beforeJobs else { throw Support.failed("Rejected preparation published late output, delivery bytes or a job.") }
            try driver.capture("preparation-finished-" + variant, target: window)
            var row: [String: Any] = ["variant": variant, "before": before, "current": current,
                "output": destination.lastPathComponent, "outputExists": false, "jobsBefore": beforeJobs.sorted(), "jobsAfter": beforeJobs.sorted(),
                "deliveryBefore": beforeFiles, "deliveryAfter": try deliveryHashes(home), "barrierExited": barrier.exited,
                "error": driver.text("export.error", in: window) as Any? ?? NSNull(), "result": driver.text("export.result", in: window) as Any? ?? NSNull()]
            if variant == "metadata" { try originalIdentity.write(to: identityURL, options: .atomic) }
            PipelineDeliveryStore.nativeAcceptanceAfterAdoptionSnapshot = nil
            let retrySource = try source(context, name: variant + "-retry-source")
            let retry = context.directory.appendingPathComponent("preparation-" + variant + "-retry.mp4")
            let job = try await Support.start(retry, context: context)
            try await Support.complete(job, context: context)
            try Support.recordJob(job, context: context, name: "preparation-" + variant + "-retry")
            let root = try ExportDataRoot.resolve(in: home)
            let finished = try Data(contentsOf: root.appendingPathComponent(FinishedTimelineManifestV1.relativePath))
            try finished.write(to: context.directory.appendingPathComponent("preparation-" + variant + "-finished.json"))
            row["retrySource"] = retrySource; row["retryJobID"] = job.id
            row["retryOutput"] = retry.lastPathComponent; row["retrySHA256"] = try FileDigest.sha256(of: retry)
            try driver.record("preparation observation " + variant, fields: row); observations.append(row)
            if variant == "timeline" || variant == "manifest" {
                try await NativeEditingOwnerAcceptance.workspace(.edit, editor: editor, window: window, driver: driver)
                guard let undoPicture = editor.clipFor(id: "picture") else { throw Support.failed("The actual Undo target disappeared.") }
                try GenericNLEAcceptance.pointerOnClip(undoPicture, editor: editor, window: window, driver: driver)
                try await driver.wait("native fixture Undo owns the document history") {
                    !(window.firstResponder is NSTextView) && window.firstResponder?.undoManager === editor.undoManager
                }
                try await key(6, "z", modifiers: .command, window: window, driver: driver)
                try await driver.wait("native fixture edit Undo after successful retry") { editor.timeline == originalTimeline && editor.mediaManifest == originalManifest }
            }
        }
        guard editor.timeline == originalTimeline, editor.mediaManifest == originalManifest,
              try Data(contentsOf: identityURL) == originalIdentity else { throw Support.failed("The preparation subpath changed its original fixture.") }
        return ["observations": observations, "destinationPanelID": panelID, "nativeMetadataUI": false]
    }

    private static func destinationPanel(_ context: Support.Context) async throws -> NSSavePanel {
        try await context.driver.click("export.start", in: context.window)
        try await context.driver.wait("actual first Save panel") { NSApp.windows.contains { ($0 as? NSSavePanel)?.isVisible == true } }
        guard let panel = NSApp.windows.compactMap({ $0 as? NSSavePanel }).first(where: \.isVisible), panel.isKeyWindow else { throw Support.failed("The real destination panel is not active.") }
        return panel
    }

    private static func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [],
                            window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        let state = KeyDelivery(), windowNumber = window.windowNumber
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            let actualWindow = event.windowNumber, actualCode = event.keyCode
            MainActor.assumeIsolated { if actualWindow == windowNumber && actualCode == code { state.delivered = true } }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        try driver.pressKey(code, characters: characters, modifiers: modifiers, in: window)
        try await driver.wait("actual key-up delivered") { state.delivered }
        try driver.record("preparation native key delivered", fields: ["code": code, "window": windowNumber])
    }

    private static func source(_ context: Support.Context, name: String) throws -> [String: String] {
        guard let home = context.editor.workingRoot else { throw Support.failed("The actual source closed.") }
        let root = try ExportDataRoot.resolve(in: home)
        let values = ["timeline": try PipelineAssemblyStore.canonical(context.editor.timeline),
            "manifest": try PlanningWriterIO.json(context.editor.mediaManifest), "metadata": try PlanningWriterIO.json(ExportDataRoot.metadata(in: root))]
        var hashes: [String: String] = [:]
        for (key, bytes) in values {
            try bytes.write(to: context.directory.appendingPathComponent("preparation-" + name + "-" + key + ".json"))
            hashes[key] = FileDigest.sha256(of: bytes)
        }
        return hashes
    }

    private static func deliveryHashes(_ home: URL) throws -> [String: String] {
        let root = try ExportDataRoot.resolve(in: home), delivery = root.appendingPathComponent("delivery")
        guard FileManager.default.fileExists(atPath: delivery.path) else { return [:] }
        guard let files = FileManager.default.enumerator(at: delivery, includingPropertiesForKeys: [.isRegularFileKey]) else { throw Support.failed("Delivery history cannot be enumerated.") }
        var hashes: [String: String] = [:]
        for case let url as URL in files {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            hashes[String(url.path.dropFirst(root.path.count + 1))] = try FileDigest.sha256(of: url)
        }
        return hashes
    }
}
