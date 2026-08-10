import Foundation

// Reconnect offline media by repointing assets at a relocated source file or folder.
extension EditorViewModel {

    /// Repoint a single asset at a new source file, re-validate, and rebuild.
    func relinkAsset(id: String, to newURL: URL) async {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        if let newType = ClipType(fileExtension: newURL.pathExtension.lowercased()), newType != asset.type {
            mediaPanelToast = "Can't relink — \"\(newURL.lastPathComponent)\" is \(newType.trackLabel.lowercased()), not \(asset.type.trackLabel.lowercased())."
            return
        }
        do {
            guard let durableURL = try await durableProjectMediaURLs(for: [newURL]).first else {
                return
            }
            applyRelink(id: id, to: durableURL, originalFilename: newURL.lastPathComponent)
            notifyTimelineChanged()
        } catch {
            mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
        }
    }

    /// Match every offline asset to a same-named file under `folder` (recursive) and relink it.
    @discardableResult
    func relinkOfflineAssets(
        fromFolder folder: URL
    ) async -> (relinked: Int, total: Int, failure: String?) {
        let offline = mediaAssets.filter { isMediaOffline($0.id) }
        guard !offline.isEmpty else { return (0, 0, nil) }
        let index = await Task.detached(priority: .userInitiated) {
            Self.fileIndex(in: folder)
        }.value
        let matches = offline.compactMap { asset -> (MediaAsset, URL)? in
            guard let match = index[asset.userFacingFilename.lowercased()] else { return nil }
            guard ClipType(fileExtension: match.pathExtension.lowercased()) == asset.type else { return nil }
            return (asset, match)
        }
        guard !matches.isEmpty else { return (0, offline.count, nil) }
        do {
            let durableURLs = try await durableProjectMediaURLs(for: matches.map { $0.1 })
            guard durableURLs.count == matches.count else {
                throw MediaImportError.copyFailed(
                    folder.lastPathComponent,
                    "not every matched file produced a durable project copy"
                )
            }
            for (match, durableURL) in zip(matches, durableURLs) {
                applyRelink(
                    id: match.0.id,
                    to: durableURL,
                    originalFilename: match.1.lastPathComponent
                )
            }
            notifyTimelineChanged()
            return (matches.count, offline.count, nil)
        } catch {
            return (0, offline.count, error.localizedDescription)
        }
    }

    private func applyRelink(id: String, to newURL: URL, originalFilename: String) {
        guard let i = mediaAssets.firstIndex(where: { $0.id == id }) else { return }
        mediaAssets[i].url = newURL
        mediaAssets[i].originalFilename = MediaFilename.normalized(originalFilename)
        if let j = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            let entry = mediaAssets[i].toManifestEntry(projectURL: workingRoot)
            mediaManifest.entries[j].source = entry.source
            mediaManifest.entries[j].originalFilename = entry.originalFilename
        }
        let asset = mediaAssets[i]
        Task { await finalizeImportedAsset(asset) }
    }

    /// Lowercased filename → URL for regular files under `folder`, first match wins.
    nonisolated private static func fileIndex(in folder: URL) -> [String: URL] {
        var map: [String: URL] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else {
            return map
        }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: keys))?.isRegularFile == true else { continue }
            let key = url.lastPathComponent.lowercased()
            if map[key] == nil { map[key] = url }
        }
        return map
    }
}
