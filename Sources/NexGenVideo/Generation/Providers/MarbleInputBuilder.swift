import Foundation

// Builds the Marble `worlds:generate` request body and reads result URLs back
// out of the completed operation. Request/response shapes follow the reference
// Python client (`scene3d/marble.py`).

enum MarbleInputBuilder {

    /// Assemble the `worlds:generate` payload: a display name, the Marble model,
    /// and a `world_prompt` carrying the base64-encoded reference image plus the
    /// geometric text prompt (mirrors marble.py `_build_image_prompt`).
    static func body(prompt: String, displayName: String, model: String, referenceImageURL: URL) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: referenceImageURL)
        } catch {
            throw GenerationBackendError.transport("Could not read Marble reference image: \(error.localizedDescription)")
        }
        let ext = referenceImageURL.pathExtension.lowercased().isEmpty ? "png" : referenceImageURL.pathExtension.lowercased()
        let body: [String: Any] = [
            "display_name": displayName,
            "model": model,
            "world_prompt": [
                "type": "image",
                "image_prompt": [
                    "source": "data_base64",
                    "data_base64": data.base64EncodedString(),
                    "extension": ext,
                    "mime_type": mimeType(forExtension: ext),
                ],
                "text_prompt": prompt,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "image/\(ext)"
        }
    }
}

enum MarbleOutput {
    /// Extract result URLs from a completed Marble operation payload. The only
    /// asset that maps onto a nexgen image asset is the equirectangular
    /// panorama (`response.assets.imagery.pano_url`).
    static func urls(from data: Data) -> [String] {
        guard
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let response = json["response"] as? [String: Any],
            let assets = response["assets"] as? [String: Any]
        else { return [] }
        if let imagery = assets["imagery"] as? [String: Any], let pano = imagery["pano_url"] as? String {
            return [pano]
        }
        return []
    }
}
