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
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                lines.append(Line(kind: .removed, number: oldIndex + 1, text: oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                lines.append(Line(kind: .inserted, number: newIndex + 1, text: newLines[newIndex]))
                newIndex += 1
            } else {
                oldIndex += 1
                newIndex += 1
            }
        }
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
