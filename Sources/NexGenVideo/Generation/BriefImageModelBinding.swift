import Foundation
import NexGenEngine

/// The image model a brief role fixes for host-run generations.
struct BriefImageModelBinding: Equatable, Sendable {
    let briefField: String
    let briefValue: String
    let roleLabel: String
    let catalogModelID: String?

    var source: String { "\(roleLabel) in the brief" }

    /// Production Design renders its lighting anchor with the Bible-images route, which falls back to
    /// the frame route when the brief leaves it unset.
    static func productionDesign(_ brief: Brief) -> Self {
        if let bible = brief.bibleImageModel {
            return Self(model: bible, field: "bible_image_model", roleLabel: "Bible images")
        }
        return Self(model: brief.frameImageModel, field: "frame_image_model", roleLabel: "Frame images")
    }

    @MainActor
    static func productionDesign(dataRoot: URL) throws -> Self {
        let brief: Brief
        do {
            brief = try YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
            try brief.validate()
        } catch {
            throw ToolError(
                "Production Design images are bound to brief.bible_image_model, but brief.yaml could not be read: "
                    + "\(error.localizedDescription) Repair the brief before generating."
            )
        }
        return productionDesign(brief)
    }

    private init(model: FrameImageModel, field: String, roleLabel: String) {
        self.briefField = field
        self.briefValue = model.rawValue
        self.roleLabel = roleLabel
        self.catalogModelID = Self.catalogModelID(for: model)
    }

    /// Host catalog id behind a brief value, or nil when no host provider offers that exact model.
    nonisolated static func catalogModelID(for model: FrameImageModel) -> String? {
        switch model {
        case .falNanoBanana, .falImagen4Ultra, .falGptImage1, .falFluxPro11,
             .falGptImage25Flare, .falGptImage25FlareEdit,
             .falGptImage25Sunburst, .falGptImage25SunburstEdit:
            return String(model.rawValue.dropFirst("fal:".count))
        case .runwayGemini3Pro, .runwayGemini31Flash, .runwayGemini25Flash,
             .runwayGen4Image, .runwayGen4ImageTurbo:
            return "runway/" + model.rawValue.dropFirst("runway:".count)
        case .googleGemini3Pro:
            return "google/gemini-3-pro-image"
        case .googleGemini31Flash:
            return "google/gemini-3.1-flash-image"
        case .googleImagen4Ultra, .openaiGptImage2, .openaiGptImage1, .other:
            return nil
        }
    }

    func liveModel(in models: [ImageModelConfig]) -> ImageModelConfig? {
        catalogModelID.flatMap { id in models.first { $0.id == id } }
    }

    func unmappedReason(in models: [ImageModelConfig]) -> String? {
        guard catalogModelID == nil else {
            return liveModel(in: models) == nil ? "\(briefValue) is not in the live model catalog." : nil
        }
        return briefValue == FrameImageModel.other.rawValue
            ? "The brief names no specific model."
            : "No connected provider in NexGenVideo offers \(briefValue)."
    }

    @MainActor
    var liveModel: ImageModelConfig? { liveModel(in: ImageModelConfig.allModels) }

    @MainActor
    var displayName: String { liveModel?.displayName ?? briefValue }

    @MainActor
    var unmappedReason: String? { unmappedReason(in: ImageModelConfig.allModels) }
}
