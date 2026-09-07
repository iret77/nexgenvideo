import AppKit
import CryptoKit
import HangDiagnostics

enum HangDiagnosticUI {
    @MainActor
    static func launch() {
        if HangDiagnosticSelfTest.requested {
            HangDiagnosticSelfTest.start()
            return
        }
        guard Bundle.main.object(forInfoDictionaryKey: "NGVDiagnosticBuild") as? Bool == true else { return }
        switch UserDefaults.standard.string(forKey: "hangDiagnosticMode") {
        case "replay": HangDiagnosticRecorder.shared.start(includeContent: true)
        case "structure": HangDiagnosticRecorder.shared.start(includeContent: false)
        case "disabled": break
        default: HangDiagnosticRecorder.shared.configure()
        }
        if let folders = try? FileManager.default.contentsOfDirectory(at: HangDiagnosticRecorder.root,
            includingPropertiesForKeys: nil), folders.contains(where: {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("pinned.json").path)
            }) {
            let alert = NSAlert()
            alert.messageText = "UI hang diagnostics saved"
            alert.informativeText = "Export the recording for analysis or delete it. No recording has been uploaded."
            alert.addButton(withTitle: "Export diagnostics…")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { export() }
        }
    }

    @MainActor
    static func export() {
        let picker = NSOpenPanel()
        picker.message = "Select the diagnostic recording to export."
        picker.directoryURL = HangDiagnosticRecorder.root
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        guard picker.runModal() == .OK, let folder = picker.url,
              folder.deletingLastPathComponent().standardizedFileURL == HangDiagnosticRecorder.root.standardizedFileURL,
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
                try FileManager.default.copyItem(at: folder, to: copy)
                let enumerator = FileManager.default.enumerator(at: copy, includingPropertiesForKeys: [.isRegularFileKey])
                var checksums: [String: String] = [:]
                while let file = enumerator?.nextObject() as? URL {
                    if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
                        checksums[file.path.replacingOccurrences(of: copy.path + "/", with: "")] = DiagnosticFiles.digest(bytes)
                    }
                }
                try DiagnosticFiles.replace(checksums, at: copy.appendingPathComponent("checksums.json"))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--keepParent", copy.path, destination.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
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
        alert.informativeText = "Recording will stop. All local hang recordings and their decryption keys will be removed. Exported copies are not removed."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete recordings")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        HangDiagnosticRecorder.shared.stop()
        HangDiagnosticRecorder.shared.deleteRecordings()
    }
}
