import Foundation
import NexGenEngine

enum PipelineShotlistWriter {
    static func write(_ shotlist: Shotlist, dataRoot: URL) throws -> URL {
        try validate(shotlist, dataRoot: dataRoot)
        do {
            return try saveShotlist(shotlist, to: dataRoot)
        } catch {
            throw ToolError("Couldn't write shot list: \(error.localizedDescription)")
        }
    }

    static func validate(_ shotlist: Shotlist, dataRoot: URL) throws {
        for shot in shotlist.shots {
            for reference in shot.referenceImageRefs {
                guard let url = projectFileURL(
                    reference,
                    dataRoot: dataRoot
                ),
                ProjectMediaExtensions.images.contains(
                    url.pathExtension.lowercased()
                ) else {
                    throw ToolError(
                        "\(shot.id).reference_image_refs must name real images "
                            + "inside the project: '\(reference)'."
                    )
                }
            }

            switch shot.sourceMode {
            case .generated:
                guard shot.sourcePath == nil else {
                    throw ToolError(
                        "\(shot.id) is generated and cannot declare source_path."
                    )
                }
            case .imported:
                guard shot.keyframeStrategy == .none,
                      !shot.chainWithPreviousEnd else {
                    throw ToolError(
                        "\(shot.id) is imported and cannot request generated "
                            + "keyframes or render chaining."
                    )
                }
            case .aiEnhanced:
                guard let sourcePath = shot.sourcePath,
                      !sourcePath.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty,
                      let sourceURL = projectFileURL(
                          sourcePath,
                          dataRoot: dataRoot
                      ),
                      ProjectMediaExtensions.videos.contains(
                          sourceURL.pathExtension.lowercased()
                      ),
                      shot.keyframeStrategy == .none,
                      !shot.chainWithPreviousEnd,
                      shot.seedanceInputMode == .keyframe,
                      shot.referenceImageRefs.isEmpty else {
                    throw ToolError(
                        "\(shot.id) is AI-enhanced and needs exactly one "
                            + "project-local source video, with no generated "
                            + "keyframes, chaining, or reference inputs."
                    )
                }
            }
        }

        let invalidChains = shotlist.shots.filter {
            $0.chainWithPreviousEnd
                && (
                    $0.sourceMode != .generated
                        || $0.keyframeStrategy != .none
                        || $0.seedanceInputMode != .keyframe
                        || !$0.referenceImageRefs.isEmpty
                        || ChainContinuity.chainPredecessor(
                            shotlist,
                            shotId: $0.id
                        ) == nil
                )
        }
        guard invalidChains.isEmpty else {
            throw ToolError(
                "Chained shots must be generated, follow an earlier renderable "
                    + "shot, use keyframe_strategy=none and "
                    + "seedance_input_mode=keyframe, and declare no reference "
                    + "images (e.g. "
                    + invalidChains.prefix(3).map(\.id).joined(separator: ", ")
                    + ")."
            )
        }

        let invalidReferenceMode = shotlist.shots.filter {
            $0.seedanceInputMode == .reference
                && (
                    $0.keyframeStrategy != .none
                        || $0.chainWithPreviousEnd
                )
        }
        guard invalidReferenceMode.isEmpty else {
            throw ToolError(
                "Reference-mode shots must use keyframe_strategy=none and "
                    + "cannot chain from a predecessor (e.g. "
                    + invalidReferenceMode.prefix(3).map(\.id)
                        .joined(separator: ", ")
                    + ")."
            )
        }
    }

    private static func projectFileURL(
        _ path: String,
        dataRoot: URL
    ) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !NSString(string: trimmed).isAbsolutePath,
              !trimmed.split(separator: "/").contains("..") else {
            return nil
        }
        let home = FrameInventory.projectHome(of: dataRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        for candidate in [
            dataRoot.appendingPathComponent(trimmed),
            home.appendingPathComponent(trimmed),
        ] {
            let resolved = candidate.standardizedFileURL
                .resolvingSymlinksInPath()
            guard resolved.path == home.path
                    || resolved.path.hasPrefix(home.path + "/") else {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue {
                return resolved
            }
        }
        return nil
    }
}
