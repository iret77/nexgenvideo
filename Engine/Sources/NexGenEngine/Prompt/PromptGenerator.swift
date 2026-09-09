import Foundation

/// Provider dispatchers for image compatibility and explicit video PromptIR dialects.
public enum PromptGenerator {
    /// Split on the first `:` — mirrors Python `model_id.split(":", 1)`.
    private static func providerAndModel(_ modelID: String) -> (provider: String, model: String) {
        if let idx = modelID.firstIndex(of: ":") {
            let provider = String(modelID[modelID.startIndex..<idx])
            let model = String(modelID[modelID.index(after: idx)...])
            return (provider, model)
        }
        return (modelID, "")
    }

    /// Port of `build_image_prompt`.
    public static func buildImagePrompt(
        modelID: String, payload: PromptPayload, sheetKind: String = "character"
    ) throws -> String {
        let (provider, model) = providerAndModel(modelID)
        if provider == "google" {
            if model.lowercased().contains("imagen") {
                return try ImageBuilders.imagen(payload, sheetKind: sheetKind)
            }
            return try ImageBuilders.nanoBanana(payload, sheetKind: sheetKind)
        }
        if provider == "openai" {
            return try ImageBuilders.gptImage2(payload, sheetKind: sheetKind)
        }
        if provider == "runway" {
            return try ImageBuilders.runwayImage(payload, sheetKind: sheetKind)
        }
        return try ImageBuilders.gptImage2(payload, sheetKind: sheetKind)
    }

    public static func buildVideoPrompt(
        modelID: String,
        payload: PromptPayload,
        hasStartImage: Bool = false,
        hasEndImage: Bool = false,
        isPacingArm: Bool = false,
        referenceTags: [ReferenceTag]? = nil
    ) -> String {
        SeedanceBuilder.build(
            payload,
            hasStartImage: hasStartImage,
            hasEndImage: hasEndImage,
            isPacingArm: isPacingArm,
            referenceTags: referenceTags
        )
    }

    public static func buildVideoPrompt(
        ir: VideoPromptIRV1,
        dialect: VideoPromptDialectV1
    ) throws -> String {
        try VideoPromptDialectCompilerV1.compile(ir, dialect: dialect)
    }
}
