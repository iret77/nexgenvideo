import AppKit

extension EditorViewModel {

    func presentRelinkPanel(for asset: MediaAsset) {
        let destination = MediaLibraryDestination(self, folderID: nil)
        let originalURL = asset.url
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the source file for \"\(asset.userFacingFilename)\""
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                guard (try? destination.validate(self)) != nil,
                      self.mediaAssets.first(where: { $0.id == asset.id }) === asset, asset.url == originalURL else {
                    self.mediaPanelToast = "The project or source changed. Relink the media again."
                    return
                }
                await self.relinkAsset(id: asset.id, to: url)
            }
        }
    }

    func relinkAsset(id: String, to newURL: URL) async {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        guard let newType = ClipType(fileExtension: newURL.pathExtension.lowercased()), newType == asset.type else {
            mediaPanelToast = "Choose a supported \(asset.type.trackLabel.lowercased()) file for \(asset.userFacingFilename)."
            return
        }
        let root = workingRoot
        let key = openWorkingCopyKey
        let generation = openWorkingCopyGeneration
        let previousURL = asset.url
        do {
            guard let durableURL = try await durableProjectMediaURLs(for: [newURL]).first else {
                return
            }
            guard workingRoot == root, openWorkingCopyKey == key, openWorkingCopyGeneration == generation,
                  mediaAssets.first(where: { $0.id == id }) === asset, asset.url == previousURL else {
                throw MediaImportError.projectChanged
            }
            applyRelink(id: id, to: durableURL, originalFilename: newURL.lastPathComponent)
            notifyTimelineChanged()
        } catch {
            mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
        }
    }

    @discardableResult
    func relinkOfflineAssets(
        fromFolder folder: URL
    ) async -> (relinked: Int, total: Int, failure: String?) {
        let offline = mediaAssets.filter { isMediaOffline($0.id) }
        guard !offline.isEmpty else { return (0, 0, nil) }
        let root = workingRoot
        let key = openWorkingCopyKey
        let generation = openWorkingCopyGeneration
        let previousURLs = Dictionary(offline.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        let index = await Task.detached(priority: .userInitiated) {
            Self.fileIndex(in: folder)
        }.value
        guard workingRoot == root, openWorkingCopyKey == key, openWorkingCopyGeneration == generation else {
            return (0, offline.count, MediaImportError.projectChanged.localizedDescription)
        }
        var ambiguous: [String] = []
        let matches = offline.compactMap { asset -> (MediaAsset, URL)? in
            let candidates = index[asset.userFacingFilename.lowercased(), default: []]
                .filter { ClipType(fileExtension: $0.pathExtension.lowercased()) == asset.type }
            guard candidates.count == 1, let match = candidates.first else {
                if candidates.count > 1 { ambiguous.append(asset.userFacingFilename) }
                return nil
            }
            return (asset, match)
        }
        let ambiguity = ambiguous.isEmpty ? nil
            : "Multiple files match " + Set(ambiguous).sorted().joined(separator: ", ") + ". Relink these files individually."
        guard !matches.isEmpty else { return (0, offline.count, ambiguity) }
        do {
            let durableURLs = try await durableProjectMediaURLs(for: matches.map { $0.1 })
            guard durableURLs.count == matches.count else {
                throw MediaImportError.copyFailed(
                    folder.lastPathComponent,
                    "not every matched file produced a durable project copy"
                )
            }
            guard workingRoot == root, openWorkingCopyKey == key, openWorkingCopyGeneration == generation, matches.allSatisfy({ match in
                mediaAssets.first(where: { $0.id == match.0.id }) === match.0
                    && match.0.url == previousURLs[match.0.id] && isMediaOffline(match.0.id)
            }) else { throw MediaImportError.projectChanged }
            undoManager?.beginUndoGrouping()
            defer { undoManager?.endUndoGrouping() }
            for (match, durableURL) in zip(matches, durableURLs) {
                applyRelink(
                    id: match.0.id,
                    to: durableURL,
                    originalFilename: match.1.lastPathComponent
                )
            }
            notifyTimelineChanged()
            undoManager?.setActionName("Relink Media")
            let failure = ambiguity.map { "Relinked \(matches.count) of \(offline.count) offline files. " + $0 }
            return (matches.count, offline.count, failure)
        } catch {
            return (0, offline.count, error.localizedDescription)
        }
    }

    private func applyRelink(id: String, to newURL: URL, originalFilename: String) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        var binding = MediaRelinkBinding(asset)
        binding.url = newURL
        binding.originalFilename = MediaFilename.normalized(originalFilename)
        binding.cachedRemoteURL = nil
        binding.cachedRemoteURLExpiresAt = nil
        restoreRelink(id: id, binding: binding)
    }

    private func restoreRelink(id: String, binding: MediaRelinkBinding) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        let previous = MediaRelinkBinding(asset)
        binding.apply(to: asset)
        if let index = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            let entry = asset.toManifestEntry(projectURL: workingRoot)
            mediaManifest.entries[index].source = entry.source
            mediaManifest.entries[index].cachedRemoteURL = entry.cachedRemoteURL
            mediaManifest.entries[index].cachedRemoteURLExpiresAt = entry.cachedRemoteURLExpiresAt
        }
        updateManifestMetadata(for: asset)
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.restoreRelink(id: id, binding: previous)
        }
        undoManager?.setActionName("Relink Media")
        refreshMissingMediaCache()
        notifyTimelineChanged()
        let root = workingRoot
        let key = openWorkingCopyKey
        let generation = openWorkingCopyGeneration
        Task {
            let metadata = MediaAsset(id: id, url: binding.url, type: asset.type, name: asset.name)
            if metadata.type == .subtitle {
                guard let parsed = try? await SubtitleFileParser.parseFile(at: binding.url) else { return }
                metadata.duration = parsed.cues.map(\.end.milliseconds).max().map { Double($0) / 1_000 } ?? 0
            } else if metadata.type != .document {
                await metadata.loadMetadata()
                guard metadata.duration.isFinite, metadata.duration > 0 else { return }
            }
            guard workingRoot == root, openWorkingCopyKey == key, openWorkingCopyGeneration == generation,
                  mediaAssets.first(where: { $0.id == id }) === asset, asset.url == binding.url else { return }
            if metadata.type != .document {
                asset.duration = metadata.duration
                asset.sourceWidth = metadata.sourceWidth
                asset.sourceHeight = metadata.sourceHeight
                asset.sourceFPS = metadata.sourceFPS
                asset.hasAudio = metadata.hasAudio
                asset.thumbnail = metadata.thumbnail
                updateManifestMetadata(for: asset)
            }
            searchIndex.schedule(asset)
            switch asset.type {
            case .video:
                mediaVisualCache.generateWaveform(for: asset)
                mediaVisualCache.generateVideoThumbnails(for: asset)
            case .audio: mediaVisualCache.generateWaveform(for: asset)
            case .image: mediaVisualCache.generateImageThumbnail(for: asset)
            case .text, .lottie, .subtitle, .document: break
            }
        }
    }

    nonisolated private static func fileIndex(in folder: URL) -> [String: [URL]] {
        var map: [String: [URL]] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else {
            return map
        }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: keys))?.isRegularFile == true else { continue }
            let key = url.lastPathComponent.lowercased()
            map[key, default: []].append(url)
        }
        return map
    }
}

@MainActor
private struct MediaRelinkBinding {
    var url: URL
    var originalFilename: String?
    var cachedRemoteURL: String?
    var cachedRemoteURLExpiresAt: Date?
    let duration: Double
    let sourceWidth: Int?
    let sourceHeight: Int?
    let sourceFPS: Double?
    let hasAudio: Bool
    let thumbnail: NSImage?

    init(_ asset: MediaAsset) {
        url = asset.url; originalFilename = asset.originalFilename
        cachedRemoteURL = asset.cachedRemoteURL; cachedRemoteURLExpiresAt = asset.cachedRemoteURLExpiresAt
        duration = asset.duration; sourceWidth = asset.sourceWidth; sourceHeight = asset.sourceHeight
        sourceFPS = asset.sourceFPS; hasAudio = asset.hasAudio; thumbnail = asset.thumbnail
    }

    func apply(to asset: MediaAsset) {
        asset.url = url; asset.originalFilename = originalFilename
        asset.cachedRemoteURL = cachedRemoteURL; asset.cachedRemoteURLExpiresAt = cachedRemoteURLExpiresAt
        asset.duration = duration; asset.sourceWidth = sourceWidth; asset.sourceHeight = sourceHeight
        asset.sourceFPS = sourceFPS; asset.hasAudio = hasAudio; asset.thumbnail = thumbnail
    }
}
