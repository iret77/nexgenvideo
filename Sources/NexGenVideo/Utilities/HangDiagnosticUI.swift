import AppKit
import CryptoKit
import HangDiagnostics

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
        if let folders = try? FileManager.default.contentsOfDirectory(at: HangDiagnosticRecorder.root,
            includingPropertiesForKeys: nil), folders.contains(where: {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("sample-request.json").path)
            }) {
            notifySaved()
        }
    }

    @MainActor
    static func notifySaved() {
        guard !HangDiagnosticSelfTest.requested, !AppRelaunchSelfTest.isRequested else { return }
        let alert = NSAlert()
        alert.messageText = "UI hang diagnostics saved"
        alert.informativeText = "Export the recording for analysis or delete it. No recording has been uploaded."
        alert.addButton(withTitle: "Export diagnostics…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { export() }
    }

    @MainActor
    static func export() {
        let picker = NSOpenPanel()
        picker.message = "Select the diagnostic recording to export."
        picker.directoryURL = HangDiagnosticRecorder.root
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        guard picker.runModal() == .OK, let folder = picker.url,
              folder.deletingLastPathComponent().standardizedFileURL.path == HangDiagnosticRecorder.root.standardizedFileURL.path,
              UUID(uuidString: folder.lastPathComponent) != nil else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = "NexGenVideo-\(folder.lastPathComponent).zip"
        guard save.runModal() == .OK, let destination = save.url else { return }
        let key = KeychainStore.load(account: "hang-diagnostic-\(folder.lastPathComponent)")
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
                    let alert = NSAlert()
                    alert.messageText = "Diagnostics exported"
                    alert.informativeText = key == nil ? "The package contains structural diagnostics only."
                        : "Replay content is encrypted. Copy its key and send it separately from the package. The package does not contain this key."
                    alert.addButton(withTitle: key == nil ? "Done" : "Copy decryption key")
                    if alert.runModal() == .alertFirstButtonReturn, let key {
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
