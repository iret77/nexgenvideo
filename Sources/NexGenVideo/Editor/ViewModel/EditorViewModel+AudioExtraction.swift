import Foundation

struct AudioTrackSelectionRequest: Identifiable, Sendable, Equatable {
    let id: UUID
    let source: AudioExtractionSource
    let tracks: [AudioTrackDescriptor]

    var sourceAssetID: String { source.assetID }
    var sourceName: String { source.name }
}

struct AudioExtractionProgress: Identifiable, Sendable, Equatable {
    enum Stage: Sendable, Equatable {
        case inspecting
        case extracting
        case saving

        var title: String {
            switch self {
            case .inspecting: "Inspecting audio"
            case .extracting: "Extracting audio"
            case .saving: "Saving audio"
            }
        }
    }

    let id: UUID
    let sourceName: String
    let stage: Stage
}

struct AudioExtractionSource: Sendable, Equatable {
    let assetID: String
    let url: URL
    let name: String
    let filename: String
    let workingRoot: URL
    let workingCopyKey: String
}

extension EditorViewModel {
    func canExtractAudio(from asset: MediaAsset) -> Bool {
        asset.type == .video
            && asset.hasAudio
            && !asset.isGenerating
            && !isMediaOffline(asset.id)
            && audioExtractionProgress == nil
            && pendingAudioTrackSelection == nil
    }

    func beginAudioExtraction(from assetID: String) {
        guard let asset = mediaAssets.first(where: { $0.id == assetID }),
              canExtractAudio(from: asset) else { return }
        guard let source = audioExtractionSource(for: asset) else {
            mediaPanelToast = MediaPanelToast(
                message: MediaImportError.projectMustBeSaved.localizedDescription
            )
            return
        }

        let operationID = UUID()
        audioExtractionProgress = AudioExtractionProgress(
            id: operationID,
            sourceName: source.name,
            stage: .inspecting
        )
        let client = audioTrackExtractionClient
        audioExtractionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let tracks = try await client.tracks(source.url)
                try Task.checkCancellation()
                guard !tracks.isEmpty else {
                    throw AudioTrackExtractor.ExtractionError(
                        reason: "source has no audio track"
                    )
                }
                if tracks.count == 1, let track = tracks.first {
                    try await self.performAudioExtraction(
                        source: source,
                        track: track,
                        trackCount: tracks.count,
                        operationID: operationID,
                        client: client
                    )
                } else {
                    guard self.audioExtractionProgress?.id == operationID else { return }
                    self.audioExtractionProgress = nil
                    self.audioExtractionTask = nil
                    self.pendingAudioTrackSelection = AudioTrackSelectionRequest(
                        id: operationID,
                        source: source,
                        tracks: tracks
                    )
                }
            } catch {
                self.finishAudioExtractionFailure(error, operationID: operationID)
            }
        }
    }

    func selectAudioTrack(_ track: AudioTrackDescriptor) {
        guard let request = pendingAudioTrackSelection,
              request.tracks.contains(track),
              workingRoot?.standardizedFileURL.resolvingSymlinksInPath()
                == request.source.workingRoot,
              openWorkingCopyKey == request.source.workingCopyKey,
              let asset = mediaAssets.first(where: { $0.id == request.sourceAssetID }),
              asset.url.standardizedFileURL.resolvingSymlinksInPath()
                == request.source.url.standardizedFileURL.resolvingSymlinksInPath() else {
            pendingAudioTrackSelection = nil
            mediaPanelToast = MediaPanelToast(message: "Audio extraction couldn't start.")
            return
        }
        let source = request.source
        pendingAudioTrackSelection = nil
        let operationID = UUID()
        audioExtractionProgress = AudioExtractionProgress(
            id: operationID,
            sourceName: source.name,
            stage: .extracting
        )
        let client = audioTrackExtractionClient
        let trackCount = request.tracks.count
        audioExtractionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.performAudioExtraction(
                    source: source,
                    track: track,
                    trackCount: trackCount,
                    operationID: operationID,
                    client: client
                )
            } catch {
                self.finishAudioExtractionFailure(error, operationID: operationID)
            }
        }
    }

    func cancelAudioTrackSelection() {
        guard pendingAudioTrackSelection != nil else { return }
        pendingAudioTrackSelection = nil
        mediaPanelToast = MediaPanelToast(message: "Audio extraction canceled.")
    }

    func cancelAudioExtraction() {
        guard audioExtractionProgress != nil else { return }
        audioExtractionTask?.cancel()
        audioExtractionTask = nil
        audioExtractionProgress = nil
        mediaPanelToast = MediaPanelToast(message: "Audio extraction canceled.")
    }

    @discardableResult
    func cancelAudioExtractionForProjectChange() -> Task<Void, Never>? {
        let task = audioExtractionTask
        task?.cancel()
        audioExtractionTask = nil
        audioExtractionProgress = nil
        pendingAudioTrackSelection = nil
        return task
    }

    private func audioExtractionSource(for asset: MediaAsset) -> AudioExtractionSource? {
        guard let workingRoot, let workingCopyKey = openWorkingCopyKey else { return nil }
        return AudioExtractionSource(
            assetID: asset.id,
            url: asset.url.standardizedFileURL.resolvingSymlinksInPath(),
            name: asset.name,
            filename: asset.userFacingFilename,
            workingRoot: workingRoot.standardizedFileURL.resolvingSymlinksInPath(),
            workingCopyKey: workingCopyKey
        )
    }

    private func performAudioExtraction(
        source: AudioExtractionSource,
        track: AudioTrackDescriptor,
        trackCount: Int,
        operationID: UUID,
        client: AudioTrackExtractionClient
    ) async throws {
        guard audioExtractionProgress?.id == operationID else {
            throw CancellationError()
        }
        audioExtractionProgress = AudioExtractionProgress(
            id: operationID,
            sourceName: source.name,
            stage: .extracting
        )

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await client.extract(source.url, track.id, temporaryURL)
        try Task.checkCancellation()

        guard audioExtractionProgress?.id == operationID else {
            throw CancellationError()
        }
        audioExtractionProgress = AudioExtractionProgress(
            id: operationID,
            sourceName: source.name,
            stage: .saving
        )
        guard workingRoot?.standardizedFileURL.resolvingSymlinksInPath() == source.workingRoot,
              openWorkingCopyKey == source.workingCopyKey,
              let currentSource = mediaAssets.first(where: { $0.id == source.assetID }),
              currentSource.url.standardizedFileURL.resolvingSymlinksInPath()
                == source.url.standardizedFileURL.resolvingSymlinksInPath() else {
            throw MediaImportError.projectChanged
        }

        let mediaDirectory = try prepareWorkingMediaDirectory()
        let reusableByDigest = Dictionary(
            mediaAssets.compactMap { asset -> (String, URL)? in
                let stem = asset.url.deletingPathExtension().lastPathComponent.lowercased()
                guard stem.count == 64, stem.allSatisfy(\.isHexDigit) else { return nil }
                return (stem, asset.url)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let stored = try await DurableMediaStore.copy(
            temporaryURL,
            into: mediaDirectory,
            reusableByDigest: reusableByDigest,
            fileExtension: "m4a"
        )
        do {
            try Task.checkCancellation()
            guard audioExtractionProgress?.id == operationID,
                  workingRoot?.standardizedFileURL.resolvingSymlinksInPath() == source.workingRoot,
                  openWorkingCopyKey == source.workingCopyKey,
                  let finalSource = mediaAssets.first(where: { $0.id == source.assetID }),
                  finalSource.url.standardizedFileURL.resolvingSymlinksInPath()
                    == source.url else {
                throw MediaImportError.projectChanged
            }

            let originalFilename = Self.extractedAudioFilename(
                sourceFilename: source.filename,
                trackNumber: track.number,
                trackCount: trackCount
            )
            let asset = MediaAsset(
                url: stored.url,
                type: .audio,
                name: URL(fileURLWithPath: originalFilename)
                    .deletingPathExtension().lastPathComponent,
                originalFilename: originalFilename
            )
            asset.folderId = finalSource.folderId
            asset.origin = MediaAssetOrigin(
                kind: .extractedAudio,
                sourceAssetID: source.assetID,
                sourceFilename: source.filename,
                audioTrackNumber: track.number,
                audioTrackLabel: track.label
            )
            importMediaAsset(asset)
            await finalizeImportedAsset(asset)
            audioExtractionProgress = nil
            audioExtractionTask = nil
            mediaPanelRevealAssetId = asset.id
            mediaPanelToast = MediaPanelToast(
                message: "Audio saved as \"\(asset.userFacingFilename)\".",
                kind: .success
            )
            Log.project.notice(
                "audio extraction finished source=\(source.assetID.prefix(8)) track=\(track.number) asset=\(asset.id.prefix(8))"
            )
        } catch {
            if stored.created,
               !mediaAssets.contains(where: {
                   $0.url.standardizedFileURL.resolvingSymlinksInPath()
                       == stored.url.standardizedFileURL.resolvingSymlinksInPath()
               }) {
                try? FileManager.default.removeItem(at: stored.url)
            }
            throw error
        }
    }

    static func extractedAudioFilename(
        sourceFilename: String,
        trackNumber: Int,
        trackCount: Int
    ) -> String {
        let normalized = MediaFilename.normalized(sourceFilename) ?? "Video"
        let stem = URL(fileURLWithPath: normalized).deletingPathExtension().lastPathComponent
        let suffix = trackCount > 1 ? "Audio Track \(trackNumber)" : "Audio"
        return "\(stem) - \(suffix).m4a"
    }

    private func finishAudioExtractionFailure(_ error: Error, operationID: UUID) {
        guard audioExtractionProgress?.id == operationID else { return }
        audioExtractionProgress = nil
        audioExtractionTask = nil
        if error is CancellationError || (error as? MediaImportError) == .cancelled {
            mediaPanelToast = MediaPanelToast(message: "Audio extraction canceled.")
        } else {
            mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            Log.project.error("audio extraction failed error=\(error.localizedDescription)")
        }
    }
}
