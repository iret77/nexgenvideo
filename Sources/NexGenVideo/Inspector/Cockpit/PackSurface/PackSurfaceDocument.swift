import Foundation
import NexGenEngine

enum PackSurfaceDataResolver {
    static func resolve(dataRoot: URL, pattern: String) -> URL? {
        var resolvedPattern = pattern
        if pattern.contains("{songStem}") {
            let songs = AudioProjectLayout.songFiles(dataRoot: dataRoot)
            guard songs.count == 1, let song = songs.first else { return nil }
            resolvedPattern = pattern.replacingOccurrences(
                of: "{songStem}",
                with: song.deletingPathExtension().lastPathComponent
            )
        }
        let components = resolvedPattern
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !resolvedPattern.hasPrefix("/"), resolvedPattern.hasSuffix(".json"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !resolvedPattern.contains("{"), !resolvedPattern.contains("}"),
              !resolvedPattern.contains("*") else { return nil }
        let candidate = components.reduce(dataRoot) { $0.appendingPathComponent($1) }
        return checkedFile(candidate, in: dataRoot)
    }

    private static func checkedFile(_ candidate: URL, in dataRoot: URL) -> URL? {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/"),
              let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return candidate
    }
}

struct PackSurfaceDocument: Sendable, Equatable {
    indirect enum Value: Decodable, Sendable, Equatable {
        case object([String: Value])
        case array([Value])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let value = try? c.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? c.decode(Double.self) {
                self = .number(value)
            } else if let value = try? c.decode(String.self) {
                self = .string(value)
            } else if let value = try? c.decode([String: Value].self) {
                self = .object(value)
            } else if let value = try? c.decode([Value].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: c,
                    debugDescription: "Unsupported cockpit surface JSON value."
                )
            }
        }
    }

    let root: Value

    init(data: Data) throws {
        root = try JSONDecoder().decode(Value.self, from: data)
    }

    func value(at path: String) -> Value? {
        path.split(separator: ".").reduce(Optional(root)) { current, component in
            guard case .object(let object)? = current else { return nil }
            return object[String(component)]
        }
    }

    func number(at path: String) -> Double? {
        guard case .number(let value)? = value(at: path), value.isFinite else { return nil }
        return value
    }

    func string(at path: String) -> String? {
        guard case .string(let value)? = value(at: path) else { return nil }
        return value
    }

    func numbers(at path: String) -> [Double]? {
        guard case .array(let values)? = value(at: path) else { return nil }
        let numbers = values.compactMap { value -> Double? in
            guard case .number(let number) = value, number.isFinite else { return nil }
            return number
        }
        return numbers.count == values.count ? numbers : nil
    }

    func count(at path: String) -> Int? {
        switch value(at: path) {
        case .array(let values)?: return values.count
        case .object(let values)?: return values.count
        default: return nil
        }
    }

    func sections(at path: String) -> [AnalysisSurfaceData.Section]? {
        guard case .array(let values)? = value(at: path) else { return nil }
        let sections = values.enumerated().compactMap { offset, value -> AnalysisSurfaceData.Section? in
            guard case .object(let object) = value,
                  case .number(let start)? = object["start"],
                  case .number(let end)? = object["end"],
                  start.isFinite, end.isFinite, end > start else { return nil }
            let index: Int
            if case .number(let rawIndex)? = object["index"],
               rawIndex.isFinite, rawIndex >= 0, rawIndex <= Double(Int.max),
               rawIndex.rounded() == rawIndex {
                index = Int(rawIndex)
            } else {
                index = offset
            }
            let label: String?
            if case .string(let value)? = object["label"] { label = value } else { label = nil }
            let source: String?
            if case .string(let value)? = object["source"] { source = value } else { source = nil }
            return AnalysisSurfaceData.Section(
                index: index,
                start: start,
                end: end,
                label: label,
                source: source
            )
        }
        return sections.count == values.count ? sections : nil
    }
}

enum PackSurfaceSectionBinding {
    static func sections(
        document: PackSurfaceDocument,
        field: String,
        visibility: CockpitBindingVisibilityData,
        analysis: AnalysisSurfaceData?
    ) -> [AnalysisSurfaceData.Section] {
        let boundSections = document.sections(at: field) ?? []
        guard visibility == .whenCanonicalSections else { return boundSections }
        guard let analysis,
              analysis.hasCanonicalStructure,
              analysis.sections == boundSections else { return [] }
        return boundSections
    }

    static func hierarchy(
        document: PackSurfaceDocument,
        field: String,
        visibility: CockpitBindingVisibilityData,
        analysis: AnalysisSurfaceData?
    ) -> [AnalysisSurfaceData.HierarchySection] {
        let boundSections = document.sections(at: field) ?? []
        if let analysis,
           analysis.sections == boundSections,
           let validated = analysis.canonicalHierarchy {
            return zip(boundSections, validated).map { section, hierarchy in
                AnalysisSurfaceData.HierarchySection(
                    id: hierarchy.id,
                    section: section,
                    segments: hierarchy.segments
                )
            }
        }
        guard visibility != .whenCanonicalSections else { return [] }
        return boundSections.enumerated().map {
            AnalysisSurfaceData.HierarchySection(
                id: $0.offset,
                section: $0.element,
                segments: []
            )
        }
    }
}
