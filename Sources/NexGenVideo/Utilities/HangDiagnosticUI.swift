import AppKit
import CryptoKit
import HangDiagnostics
import UniformTypeIdentifiers

enum HangDiagnosticUI {
    @MainActor
    static func launch() {
        guard !AppRelaunchSelfTest.isRequested else { return }
        if HangDiagnosticSelfTest.requested {
            HangDiagnosticSelfTest.start()
            return
        }
        guard Bundle.main.object(forInfoDictionaryKey: "NGVDiagnosticBuild") as? Bool == true else { return }
        HangDiagnosticRecorder.shared.pruneExpiredRecordings()
        switch UserDefaults.standard.string(forKey: "hangDiagnosticMode") {
        case "replay": HangDiagnosticRecorder.shared.start(includeContent: true)
        case "structure": HangDiagnosticRecorder.shared.start(includeContent: false)
        case "disabled": break
        default: HangDiagnosticRecorder.shared.configure()
        }
        notifySaved()
    }

    @MainActor
    static func notifySaved() {
        guard !HangDiagnosticSelfTest.requested, !AppRelaunchSelfTest.isRequested else { return }
        guard let folders = try? FileManager.default.contentsOfDirectory(at: HangDiagnosticRecorder.root,
            includingPropertiesForKeys: nil) else { return }
        let requests = folders.compactMap { folder -> String? in
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("sample-request.json")),
                  let request = try? JSONDecoder().decode(String.self, from: data),
                  UUID(uuidString: request) != nil else { return nil }
            return "\(folder.lastPathComponent)/\(request)"
        }
        // Persist before the modal loop so queued notifications cannot present it again.
        let pendingRequests = DiagnosticNotifications.acknowledge(requests)
        guard !pendingRequests.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "UI hang diagnostics saved"
        alert.informativeText = "Export the recording for analysis or delete it. No recording has been uploaded."
        alert.addButton(withTitle: "Export diagnostics…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let pending = folders.filter { folder in
                pendingRequests.contains { $0.hasPrefix(folder.lastPathComponent + "/") }
            }
            export(recordings: pending)
        }
    }

    @MainActor
    static func export() {
        do {
            let folders = try FileManager.default.contentsOfDirectory(at: HangDiagnosticRecorder.root,
                includingPropertiesForKeys: [.creationDateKey])
            export(recordings: folders.filter { UUID(uuidString: $0.lastPathComponent) != nil })
        } catch {
            let alert = NSAlert()
            alert.messageText = "No diagnostic recordings available"
            alert.informativeText = "Recordings appear here after hang recording has started."
            alert.runModal()
        }
    }

    @MainActor
    private static func export(recordings: [URL]) {
        let folders = recordings.sorted { lhs, rhs in
            let leftHang = FileManager.default.fileExists(atPath: lhs.appendingPathComponent("sample-request.json").path)
            let rightHang = FileManager.default.fileExists(atPath: rhs.appendingPathComponent("sample-request.json").path)
            if leftHang != rightHang { return leftHang }
            let leftDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return leftDate > rightDate
        }
        guard !folders.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No diagnostic recordings available"
            alert.runModal()
            return
        }
        var selectedIndex = 0
        if folders.count > 1 {
            let picker = NSPopUpButton()
            picker.addItems(withTitles: folders.map { recordingLabel($0) })
            picker.sizeToFit()
            let alert = NSAlert()
            alert.messageText = "Export diagnostic recording"
            alert.informativeText = "Select a session. Sessions with a recorded hang appear first. Next, choose where to save the ZIP."
            alert.accessoryView = picker
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            selectedIndex = picker.indexOfSelectedItem
        }
        guard folders.indices.contains(selectedIndex) else { return }
        let folder = folders[selectedIndex]
        let hasReplay = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .contains { $0.hasPrefix("replay-") && $0.hasSuffix(".enc") }
        let key = KeychainStore.load(account: "hang-diagnostic-\(folder.lastPathComponent)")
        let save = NSSavePanel()
        save.title = "Export diagnostic recording"
        save.prompt = "Export"
        save.message = "\(recordingLabel(folder))\nSave a ZIP copy for analysis. The original recording stays on this Mac."
        save.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        save.allowedContentTypes = [.zip]
        save.nameFieldStringValue = "NexGenVideo-\(folder.lastPathComponent).zip"
        guard save.runModal() == .OK, let destination = save.url else { return }
        Task.detached(priority: .utility) {
            do {
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try DiagnosticFiles.directory(staging)
                defer { try? FileManager.default.removeItem(at: staging) }
                let copy = staging.appendingPathComponent(folder.lastPathComponent)
                try await HangDiagnosticRecorder.shared.stageExport(from: folder, to: copy)
                let process = Process()
                let archive = staging.appendingPathComponent("recording.zip")
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--keepParent", copy.path, archive.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
                let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
                defer { try? FileManager.default.removeItem(at: partial) }
                try FileManager.default.copyItem(at: archive, to: partial)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
                guard rename(partial.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    let alert = NSAlert()
                    alert.messageText = "Diagnostics exported"
                    let details = !hasReplay ? "The package contains structural diagnostics only."
                        : key == nil ? "The package includes encrypted replay content, but its key is unavailable. Thread stacks and event records remain readable."
                        : "Replay content is encrypted. Copy its key and send it separately from the ZIP. Keep both for analysis."
                    alert.informativeText = "Saved to \(destination.path)\n\n\(details)"
                    alert.addButton(withTitle: hasReplay && key != nil ? "Copy decryption key" : "Done")
                    if hasReplay && key != nil { alert.addButton(withTitle: "Done") }
                    if alert.runModal() == .alertFirstButtonReturn, hasReplay, let key {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key, forType: .string)
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Diagnostic export failed"
                    alert.informativeText = "The original recording has not been removed."
                    alert.runModal()
                }
            }
        }
    }

    @MainActor
    private static func recordingLabel(_ folder: URL) -> String {
        let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
            .map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "Unknown date"
        let hasHang = FileManager.default.fileExists(atPath: folder.appendingPathComponent("sample-request.json").path)
        return "\(date) · \(hasHang ? "Hang recorded" : "No hang recorded") · \(folder.lastPathComponent.prefix(8))"
    }

    @MainActor
    static func delete() {
        let alert = NSAlert()
        alert.messageText = "Delete local hang recordings?"
        alert.informativeText = "Recording will stop. Recorder sessions and their decryption keys will be removed. Legacy crash logs and exported copies are kept."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete recordings")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        HangDiagnosticRecorder.shared.stop()
        Task { @MainActor in
            let result = NSAlert()
            do {
                try await HangDiagnosticRecorder.shared.deleteRecordings()
                result.messageText = "Local hang recordings deleted"
                result.informativeText = "Exported copies and legacy crash logs were kept. Restart NexGenVideo to record again."
            } catch {
                result.messageText = "Some recordings could not be deleted"
                result.informativeText = "Close other NexGenVideo instances and try again. Exported copies and legacy crash logs were kept."
            }
            result.runModal()
        }
    }
}
