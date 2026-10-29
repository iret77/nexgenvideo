import Foundation

extension ToolExecutor {
    private static let searchMediaAllowedKeys: Set<String> = ["query", "scope", "mediaRef", "limit"]

    func searchMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let root = editor.workingRoot
        let key = editor.openWorkingCopyKey
        let generation = editor.openWorkingCopyGeneration
        let sources = Dictionary(editor.mediaAssets.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        try validateUnknownKeys(args, allowed: Self.searchMediaAllowedKeys, path: "search_media")
        let query = try args.requireString("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError("search_media: query is empty") }
        let scope = args.string("scope") ?? "both"
        guard ["visual", "spoken", "both"].contains(scope) else {
            throw ToolError("search_media: scope must be visual, spoken, or both (got '\(scope)')")
        }
        let limit = min(max(args.int("limit") ?? 10, 1), 50)
        var restrict: Set<String>?
        if let ref = args.string("mediaRef") {
            restrict = [try asset(ref, editor: editor).id]
        }

        var payload: [String: Any] = [:]
        if scope != "spoken" {
            payload.merge(await visualResults(editor, query: query, limit: limit, restrict: restrict)) { _, new in new }
        }
        if scope != "visual" {
            payload.merge(await spokenResults(editor, query: query, limit: limit, restrict: restrict)) { _, new in new }
        }

        guard root == editor.workingRoot, key == editor.openWorkingCopyKey, generation == editor.openWorkingCopyGeneration,
              sources == Dictionary(editor.mediaAssets.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first }) else {
            throw ToolError("search_media: the project or media library changed during search. Search again.")
        }
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("search_media: failed to encode results")
        }
        return .ok(json)
    }

    private func visualResults(
        _ editor: EditorViewModel, query: String, limit: Int, restrict: Set<String>?
    ) async -> [String: Any] {
        let coordinator = editor.searchIndex
        if VisualModelLoader.shared.enabled, VisualModelLoader.shared.state == .unknown {
            await VisualModelLoader.shared.prepare()
        }

        let result = await coordinator.searchResult(query: query, limit: limit, within: restrict)
        let indexable = editor.mediaAssets.filter {
            ($0.type == .video || $0.type == .image) && (restrict?.contains($0.id) ?? true)
        }
        var payload: [String: Any] = [
            "status": VisualSearchPresentation.code(for: result.status),
            "indexableAssets": indexable.count,
            "indexedAssets": max(0, indexable.count - result.unavailableAssetIDs.count),
            "unavailableMediaRefs": result.unavailableAssetIDs.sorted(),
            "failedMediaRefs": result.failedAssetIDs.sorted(),
        ]
        if result.status != .ready { payload["statusMessage"] = VisualSearchPresentation.message(for: result.status) }
        let hits = result.hits
        payload["moments"] = hits.map { hit -> [String: Any] in
            let asset = editor.mediaAssets.first { $0.id == hit.assetID }
            var entry: [String: Any] = [
                "mediaRef": hit.assetID,
                "name": asset?.libraryDisplayName ?? "",
                "score": Double(hit.score),
            ]
            if asset?.type == .image {
                entry["type"] = "image"
            } else {
                entry["startSeconds"] = hit.shotStart
                entry["endSeconds"] = hit.shotEnd
            }
            return entry
        }
        return payload
    }

    private func spokenResults(
        _ editor: EditorViewModel, query: String, limit: Int, restrict: Set<String>?
    ) async -> [String: Any] {
        let candidates = editor.mediaAssets
            .filter { SearchIndexCoordinator.wantsTranscript($0) && (restrict?.contains($0.id) ?? true) }
            .map { (id: $0.id, url: $0.url) }
        let result = await TranscriptSearch.resultAsync(query: query, assets: candidates, limit: limit)
        let hits: [[String: Any]] = result.hits.map { hit in
            [
                "mediaRef": hit.assetID,
                "name": editor.mediaAssets.first { $0.id == hit.assetID }?.libraryDisplayName ?? "",
                "startSeconds": hit.start,
                "endSeconds": hit.end,
                "text": hit.text,
            ]
        }
        return ["spoken": hits, "spokenStatus": result.unavailableAssetIDs.isEmpty ? "ready" : "notIndexed",
                "spokenUnavailableMediaRefs": result.unavailableAssetIDs.sorted()]
    }

}
