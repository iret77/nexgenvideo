import Foundation
import ImageIO
import NexGenEngine

enum ProductionPlanningPresentation {
    private static let sketchPreviewPixels = 1280

    struct ScriptReview: Sendable {
        let script: ScriptV1
        let treatmentExcerpts: [String: [String]]
        let sourceExcerpts: [String: [String]]
    }

    static func scriptReview(dataRoot: URL) throws -> ScriptReview {
        let value = try script(dataRoot: dataRoot)
        let treatment = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: dataRoot, approval: false)
        let beats = Dictionary(uniqueKeysWithValues: treatment.beats.map { ($0.id, $0.excerpt) })
        var sources: [String: Data] = [:]
        for input in value.header.inputs {
            sources[input.id] = try Data(contentsOf: ProjectLocalFile.requireHash(input.sha256, at: input.path, dataRoot: dataRoot))
        }
        var treatmentExcerpts: [String: [String]] = [:]
        var sourceExcerpts: [String: [String]] = [:]
        for event in value.events {
            treatmentExcerpts[event.id] = event.treatmentBeatIDs.compactMap { beats[$0] }
            sourceExcerpts[event.id] = try event.sourceAnchors.map { anchor in
                guard let bytes = sources[anchor.sourceID], anchor.startByte >= 0,
                      anchor.endByte > anchor.startByte, anchor.endByte <= bytes.count else {
                    throw ToolError("The Script source changed. Reload the Script to inspect its references.")
                }
                let excerpt = bytes.subdata(in: anchor.startByte..<anchor.endByte)
                guard FileDigest.sha256(of: excerpt) == anchor.excerptSHA256,
                      let text = String(data: excerpt, encoding: .utf8) else {
                    throw ToolError("The Script source changed. Reload the Script to inspect its references.")
                }
                return text
            }
        }
        return ScriptReview(script: value, treatmentExcerpts: treatmentExcerpts, sourceExcerpts: sourceExcerpts)
    }

    static func sketchImages(_ snapshot: StoryboardBundleSnapshot, dataRoot: URL) throws -> [String: CGImage] {
        var images: [String: CGImage] = [:]
        var byHash: [String: CGImage] = [:]
        for moment in snapshot.timing.shots.flatMap(\.moments) {
            guard let asset = moment.asset, snapshot.sketchProblems[moment.id] == nil else { continue }
            if let image = byHash[asset.image.sha256] { images[moment.id] = image; continue }
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(asset.image.path, dataRoot: dataRoot))
            guard FileDigest.sha256(of: bytes) == asset.image.sha256,
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: sketchPreviewPixels,
                  ] as CFDictionary) else {
                throw ToolError("A Storyboard sketch changed or could not be decoded. Reload or replace the sketch.")
            }
            images[moment.id] = image
            byHash[asset.image.sha256] = image
        }
        return images
    }

    static func script(dataRoot: URL) throws -> ScriptV1 {
        let path = try ProjectLocalFile.resolve(ScriptV1.currentPath, dataRoot: dataRoot)
        let value = try JSONDecoder().decode(ScriptV1.self, from: Data(contentsOf: path))
        let treatment = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: dataRoot, approval: false)
        var sources: [String: Data] = [:]
        for input in value.header.inputs {
            sources[input.id] = try Data(contentsOf: ProjectLocalFile.requireHash(input.sha256, at: input.path, dataRoot: dataRoot))
        }
        return try ProductionPlanningStoreV1.readScript(dataRoot: dataRoot,
            treatmentBeatIDs: Set(treatment.beats.map(\.id)), sourceBytes: sources)
    }
}

extension EditorViewModel {
    var usesProductionPlanningV2: Bool {
        if declaredProductionContract == .current { return declaredPluginBinding == nil }
        guard let binding = declaredPluginBinding else { return false }
        return binding.id == "musicvideo" && binding.version == "0.6.0" && binding.projectSchema == "musicvideo/3.0.0"
    }
}
