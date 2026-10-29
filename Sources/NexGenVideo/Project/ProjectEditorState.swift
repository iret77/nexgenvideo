import Foundation

// Portable editing layout is separate from canonical film bytes.
enum ProjectEditorState {
    static let filename = "editor-state.json"

    private struct Stored: Codable {
        let schema: Int
        let trackHeights: [String: Double]
    }

    private struct Height: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Double.self) }
    }

    private struct Readable: Decodable {
        let schema: Int
        let trackHeights: [String: Height]
    }

    static func capture(_ timeline: Timeline) throws -> Data {
        var heights: [String: Double] = [:]
        for track in timeline.tracks { heights[track.id] = validated(Double(track.displayHeight)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Stored(schema: 1, trackHeights: heights))
    }

    static func restoring(_ data: Data?, to timeline: Timeline) -> Timeline {
        let state = data.flatMap { try? JSONDecoder().decode(Readable.self, from: $0) }
        var result = timeline
        for index in result.tracks.indices {
            let height = state?.schema == 1 ? state?.trackHeights[result.tracks[index].id]?.value : nil
            result.tracks[index].displayHeight = CGFloat(validated(height))
        }
        return result
    }

    static func read(in root: URL) -> Data? {
        let url = root.appendingPathComponent(filename)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path == root.standardizedFileURL.resolvingSymlinksInPath().path else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func validated(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= Double(AppTheme.Timeline.trackMinHeight),
              value <= Double(AppTheme.Timeline.trackMaxHeight) else { return Double(AppTheme.Layout.trackHeight) }
        return value
    }
}
