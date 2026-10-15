import Foundation
import NexGenEngine

/// Line changes between the last approved artifact text and the version offered for approval.
enum ArtifactLineDiff {
    static let maximumBytes = 256 * 1_024
    static let maximumLines = 400

    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case removed
            case inserted
        }

        let kind: Kind
        let number: Int
        let text: String
    }

    struct Result: Equatable, Sendable {
        let lines: [Line]
        let totalChangedLines: Int

        var isTruncated: Bool { totalChangedLines > lines.count }
    }

    static func changes(old: String, new: String) -> Result {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let lines = newLines.difference(from: oldLines).map { change -> Line in
            switch change {
            case .remove(let offset, let element, _):
                Line(kind: .removed, number: offset + 1, text: element)
            case .insert(let offset, let element, _):
                Line(kind: .inserted, number: offset + 1, text: element)
            }
        }
        .sorted { ($0.number, $0.kind == .removed ? 0 : 1) < ($1.number, $1.kind == .removed ? 0 : 1) }
        return Result(lines: Array(lines.prefix(maximumLines)), totalChangedLines: lines.count)
    }

    /// Project-local UTF-8 text whose bytes still hash to `sha256`; nil for anything the host cannot prove.
    static func verifiedText(path: String, sha256: String, dataRoot: URL?) -> String? {
        guard let dataRoot,
              let url = try? ProjectLocalFile.resolve(path, dataRoot: dataRoot),
              let data = try? Data(contentsOf: url),
              data.count <= maximumBytes,
              FileDigest.sha256(of: data) == sha256 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
