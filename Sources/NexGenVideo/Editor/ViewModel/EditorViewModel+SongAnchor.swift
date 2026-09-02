import AVFoundation
import Foundation
import NexGenEngine

enum SongAnchorError: LocalizedError {
    case unsupported(String)
    case sourceUnavailable(String)
    case invalidAudio(String)
    case replacementRequired([String])
    case preparationFailed(String)
    case placementFailed
    case projectChanged
    case formatChanged(String)
    case alreadyInProgress

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            "Choose a supported audio file for the project song: \(name)."
        case .sourceUnavailable(let detail):
            "Couldn't read the project song: \(detail)"
        case .invalidAudio(let detail):
            "Couldn't decode the project song: \(detail)"
        case .replacementRequired(let names):
            "audio/ already holds a different song (\(names.joined(separator: ", "))). Pass replace: true to swap it."
        case .preparationFailed(let detail):
            "Couldn't prepare the project song: \(detail)"
        case .placementFailed:
            "Couldn't place the project song on the timeline."
        case .projectChanged:
            "The project changed while the song was being prepared. Attach it again."
        case .formatChanged(let detail):
            "The project format changed while the song was being prepared: \(detail)"
        case .alreadyInProgress:
            "Another project song is still being attached. Wait for it to finish."
        }
    }
}

struct SongAnchorResult: Sendable {
    let assetId: String
    let filename: String
    let replaced: Bool
}

private struct PreparedProjectSong: Sendable {
    let audioDirectory: URL
    let stagingAudioDirectory: URL
    let destinationFilename: String
    let durableCopy: DurableMediaCopy
    let duration: Double
    let currentDigest: String?
    let currentNames: [String]

    func discard(removeDurableCopy: Bool) {
        try? FileManager.default.removeItem(at: stagingAudioDirectory)
        if removeDurableCopy, durableCopy.created {
            try? FileManager.default.removeItem(at: durableCopy.url)
        }
    }
}

extension EditorViewModel {
    func attachProjectSong(
        from sourceURL: URL,
        dataRoot: URL,
        replace: Bool,
        originalFilename: String? = nil,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) async throws -> SongAnchorResult {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let ext = source.pathExtension.lowercased()
        guard AudioProjectLayout.audioExtensions.contains(ext) else {
            throw SongAnchorError.unsupported(source.lastPathComponent)
        }
        guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw SongAnchorError.sourceUnavailable(source.path)
        }
        guard !songAttachInProgress else {
            throw SongAnchorError.alreadyInProgress
        }
        let destinationFilename = MediaFilename.storageFilename(
            originalFilename ?? source.lastPathComponent,
            matchingExtension: source.pathExtension
        ) ?? source.lastPathComponent
        songAttachInProgress = true
        defer { songAttachInProgress = false }

        let projectHome = FrameInventory.projectHome(of: dataRoot)
        do {
            _ = try ProjectPackGate.requireLiveMutation(
                projectURL: projectHome,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
        } catch {
            throw SongAnchorError.formatChanged(error.localizedDescription)
        }
        let expectedWorkingRoot = workingRoot?.standardizedFileURL
        let expectedWorkingCopyKey = openWorkingCopyKey
        let mediaDirectory = projectHome.appendingPathComponent(
            Project.mediaDirectoryName,
            isDirectory: true
        )
        if let key = openWorkingCopyKey {
            try ProjectWorkingCopy.markDirty(key: key)
        }
        do {
            try FileManager.default.createDirectory(
                at: mediaDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw SongAnchorError.preparationFailed(error.localizedDescription)
        }
        let prepared: PreparedProjectSong
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepareProjectSong(
                    source,
                    destinationFilename: destinationFilename,
                    dataRoot: dataRoot,
                    mediaDirectory: mediaDirectory
                )
            }.value
        } catch let error as SongAnchorError {
            throw error
        } catch {
            throw SongAnchorError.preparationFailed(error.localizedDescription)
        }
        guard workingRoot?.standardizedFileURL == expectedWorkingRoot,
              openWorkingCopyKey == expectedWorkingCopyKey else {
            prepared.discard(removeDurableCopy: prepared.durableCopy.created)
            throw SongAnchorError.projectChanged
        }
        do {
            _ = try ProjectPackGate.requireLiveMutation(
                projectURL: projectHome,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
        } catch {
            prepared.discard(removeDurableCopy: prepared.durableCopy.created)
            throw SongAnchorError.formatChanged(error.localizedDescription)
        }

        let sameSongContent = prepared.currentDigest == prepared.durableCopy.digest
            && prepared.currentNames.count == 1
        let pipelineSongReady = sameSongContent
            && prepared.currentNames == [prepared.destinationFilename]
        if !sameSongContent, !prepared.currentNames.isEmpty, !replace {
            prepared.discard(removeDurableCopy: prepared.durableCopy.created)
            throw SongAnchorError.replacementRequired(prepared.currentNames)
        }

        let before = mediaLibraryUndoSnapshot()
        let previousAnchorId = mediaManifest.songAnchorAssetId
        let previousAnchorOwned = mediaManifest.songAnchorOwnsAsset
        let previousDigest = prepared.currentDigest
        let existing = mediaAssets.first {
            $0.url.standardizedFileURL.resolvingSymlinksInPath()
                == prepared.durableCopy.url.standardizedFileURL.resolvingSymlinksInPath()
        }
        let previousOriginalFilename = existing?.originalFilename
        let previousDuration = existing?.duration
        let song = existing ?? MediaAsset(
            url: prepared.durableCopy.url,
            type: .audio,
            name: URL(fileURLWithPath: destinationFilename)
                .deletingPathExtension().lastPathComponent,
            duration: prepared.duration,
            originalFilename: destinationFilename
        )
        song.duration = prepared.duration
        song.originalFilename = destinationFilename
        let ownsSongAsset = existing == nil
            || (previousAnchorId == song.id && previousAnchorOwned)

        var anchorIds = Set([song.id])
        if let previousAnchorId { anchorIds.insert(previousAnchorId) }
        if let previousDigest {
            for asset in mediaAssets where Self.contentDigestStem(asset.url) == previousDigest {
                anchorIds.insert(asset.id)
            }
        }

        do {
            _ = try ProjectPackGate.requireLiveMutation(
                projectURL: projectHome,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
            if existing == nil {
                mediaAssets.append(song)
                mediaManifest.entries.append(
                    song.toManifestEntry(projectURL: workingRoot ?? projectHome)
                )
            } else {
                updateManifestMetadata(for: song)
            }
            try placeProjectSong(song, replacingAnchorIds: anchorIds)
            mediaManifest.songAnchorAssetId = song.id
            mediaManifest.songAnchorOwnsAsset = ownsSongAsset
            mediaManifest.intakeRoleByAssetID[song.id] = "song"

            if !pipelineSongReady {
                _ = try ProjectPackGate.requireLiveMutation(
                    projectURL: projectHome,
                    declaredPack: declaredPack,
                    declaredBinding: declaredBinding
                )
                _ = try FileManager.default.replaceItemAt(
                    prepared.audioDirectory,
                    withItemAt: prepared.stagingAudioDirectory
                )
            } else {
                try? FileManager.default.removeItem(at: prepared.stagingAudioDirectory)
            }

            if let previousAnchorId, previousAnchorId != song.id {
                mediaManifest.intakeRoleByAssetID.removeValue(forKey: previousAnchorId)
                if previousAnchorOwned {
                    let retiredURL = mediaAssets.first { $0.id == previousAnchorId }?.url
                    mediaAssets.removeAll { $0.id == previousAnchorId }
                    mediaManifest.entries.removeAll { $0.id == previousAnchorId }
                    if let retiredURL,
                       !mediaAssets.contains(where: {
                           $0.url.standardizedFileURL == retiredURL.standardizedFileURL
                       }) {
                        try? FileManager.default.removeItem(at: retiredURL)
                    }
                }
            }
        } catch {
            applyMediaLibrarySnapshot(before)
            if let existing {
                existing.originalFilename = previousOriginalFilename
                existing.duration = previousDuration ?? existing.duration
            }
            prepared.discard(removeDurableCopy: prepared.durableCopy.created)
            if let error = error as? SongAnchorError { throw error }
            throw SongAnchorError.preparationFailed(error.localizedDescription)
        }

        refreshMissingMediaCache()
        searchIndex.schedule(song)
        mediaVisualCache.generateWaveform(for: song)
        notifyTimelineChanged()
        onPipelineChanged?()
        return SongAnchorResult(
            assetId: song.id,
            filename: prepared.destinationFilename,
            replaced: !sameSongContent && !prepared.currentNames.isEmpty
        )
    }

    private func placeProjectSong(
        _ song: MediaAsset,
        replacingAnchorIds anchorIds: Set<String>
    ) throws {
        let existingSongClips = timeline.tracks
            .filter { $0.type == .audio }
            .flatMap(\.clips)
            .filter { anchorIds.contains($0.mediaRef) }
        if existingSongClips.count == 1,
           existingSongClips[0].mediaRef == song.id,
           existingSongClips[0].startFrame == 0 {
            return
        }

        var preferredTrackIndex: Int?
        for index in timeline.tracks.indices where timeline.tracks[index].type == .audio {
            if timeline.tracks[index].clips.contains(where: {
                anchorIds.contains($0.mediaRef)
            }) {
                preferredTrackIndex = index
            }
            timeline.tracks[index].clips.removeAll {
                anchorIds.contains($0.mediaRef)
            }
        }
        let trackIndex = preferredTrackIndex
            ?? timeline.tracks.firstIndex { $0.type == .audio }
            ?? insertTrack(at: timeline.tracks.count, type: .audio)
        let frames = max(
            1,
            Int((song.duration * Double(timeline.fps)).rounded())
        )
        let clipIds = placeClip(
            asset: song,
            trackIndex: trackIndex,
            startFrame: 0,
            durationFrames: frames,
            addLinkedAudio: false
        )
        guard clipIds.count == 1 else {
            throw SongAnchorError.placementFailed
        }
    }

    nonisolated private static func prepareProjectSong(
        _ source: URL,
        destinationFilename: String,
        dataRoot: URL,
        mediaDirectory: URL
    ) throws -> PreparedProjectSong {
        let fm = FileManager.default
        let audioDirectory = dataRoot.appendingPathComponent("audio", isDirectory: true)
        let staging = dataRoot.appendingPathComponent(
            ".song-\(UUID().uuidString).partial",
            isDirectory: true
        )
        var durableCopy: DurableMediaCopy?
        do {
            try fm.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let currentSongs = AudioProjectLayout.songFiles(dataRoot: dataRoot)
            let currentDigest = currentSongs.count == 1
                ? try DurableMediaStore.digest(of: currentSongs[0])
                : nil
            try fm.copyItem(at: audioDirectory, to: staging)
            for song in try fm.contentsOfDirectory(
                at: staging,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) where AudioProjectLayout.audioExtensions.contains(
                song.pathExtension.lowercased()
            ) {
                try fm.removeItem(at: song)
            }
            let stagedSong = staging.appendingPathComponent(destinationFilename)
            try fm.copyItem(at: source, to: stagedSong)

            let copy = try DurableMediaStore.copy(
                source,
                into: mediaDirectory,
                reusableByDigest: [:]
            )
            durableCopy = copy
            let audio = try AVAudioFile(forReading: copy.url)
            guard audio.length > 0, audio.processingFormat.sampleRate > 0 else {
                throw SongAnchorError.invalidAudio(
                    "\(source.lastPathComponent) contains no decodable audio frames."
                )
            }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            return PreparedProjectSong(
                audioDirectory: audioDirectory,
                stagingAudioDirectory: staging,
                destinationFilename: destinationFilename,
                durableCopy: copy,
                duration: duration,
                currentDigest: currentDigest,
                currentNames: currentSongs.map(\.lastPathComponent).sorted()
            )
        } catch {
            try? fm.removeItem(at: staging)
            if let durableCopy, durableCopy.created {
                try? fm.removeItem(at: durableCopy.url)
            }
            if let error = error as? SongAnchorError { throw error }
            if let error = error as? MediaImportError {
                throw SongAnchorError.preparationFailed(error.localizedDescription)
            }
            throw SongAnchorError.preparationFailed(error.localizedDescription)
        }
    }

    nonisolated private static func contentDigestStem(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        guard stem.count == 64, stem.allSatisfy(\.isHexDigit) else { return nil }
        return stem
    }
}
