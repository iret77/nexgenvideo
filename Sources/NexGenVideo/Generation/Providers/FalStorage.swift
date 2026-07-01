import Foundation

// Uploads a local file to fal storage and returns the hosted URL usable as
// `image_url` / `image_urls` in any model input. Two-step REST flow (no SDK):
// initiate → PUT the bytes. Mirrors what `@fal-ai/client` sends.
// Host is `rest.fal.ai` (the old `rest.alpha.fal.ai` is superseded).
enum FalStorage {
    private static let initiateURL = "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3"

    static func upload(fileURL: URL, contentType: String, apiKey: String) async throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw GenerationBackendError.transport("Reference read failed: \(error.localizedDescription)")
        }

        // Step 1 — initiate: ask fal for a presigned PUT target + the final URL.
        guard let initiate = URL(string: initiateURL) else {
            throw GenerationBackendError.transport("fal storage: bad initiate URL")
        }
        var initReq = URLRequest(url: initiate)
        initReq.httpMethod = "POST"
        initReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        initReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "content_type": contentType,
            "file_name": fileURL.lastPathComponent,
        ])

        let (initData, initResp) = try await URLSession.shared.data(for: initReq)
        guard (initResp as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? false,
              let json = (try? JSONSerialization.jsonObject(with: initData)) as? [String: Any],
              let uploadURLString = json["upload_url"] as? String,
              let fileURLString = json["file_url"] as? String,
              let uploadURL = URL(string: uploadURLString)
        else {
            throw GenerationBackendError.transport("fal storage initiate failed")
        }

        // Step 2 — PUT the raw bytes to the presigned URL (no Authorization header).
        var putReq = URLRequest(url: uploadURL)
        putReq.httpMethod = "PUT"
        putReq.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, putResp) = try await URLSession.shared.upload(for: putReq, from: data)
        guard (putResp as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? false else {
            throw GenerationBackendError.transport("fal storage upload failed")
        }

        return fileURLString
    }
}
