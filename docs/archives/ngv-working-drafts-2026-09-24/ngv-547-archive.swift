import Foundation

public struct ProductionKnowledgeArchive34: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public let kind: String
        public let archiveSHA256: String
        public let path: String
        public let startLine: Int
        public let endLine: Int
        public let sha256: String
        public let localDocument: String
    }

    public struct Record: Codable, Sendable {
        public let id: String
        public let sectionID: String
        public let title: String
        public let kind: String
        public let text: String
        public let sha256: String
        public let source: Source
        public let startCharacter: Int?
        public let endCharacter: Int?
        public let applicationContract: String
        public let consumers: [String]
        public let disposition: String
    }

    public struct Technique: Codable, Sendable {
        public let id: String
        public let name: String
        public let techniqueEntryIDs: [String]
        public let sharedUnitIDs: [String]
    }

    public struct Receipt: Codable, Sendable {
        public let sourceVersion: String
        public let archiveSHA256: String
        public let recordID: String
        public let sha256: String
        public let utf8Bytes: Int
    }

    public struct Read: Codable, Sendable {
        public let record: Record
        public let receipt: Receipt
    }

    public let schemaVersion: String
    public let sourceVersion: String
    public let archiveSHA256: String
    public let license: String
    public let precedence: String
    public let records: [Record]
    public let techniques: [Technique]

    public func read(_ id: String) throws -> Read {
        guard let record = records.first(where: { $0.id == id }) else {
            throw ProductionKnowledgeErrorV1.missingResource("3.4/\(id)")
        }
        guard FileDigest.sha256(of: Data(record.text.utf8)) == record.sha256 else {
            throw ProductionKnowledgeErrorV1.invalidValue(path: id, reason: "record bytes changed")
        }
        return Read(record: record, receipt: Receipt(sourceVersion: sourceVersion,
            archiveSHA256: archiveSHA256, recordID: id, sha256: record.sha256,
            utf8Bytes: record.text.utf8.count))
    }

    public func readTechnique(_ id: String) throws -> [Read] {
        guard let technique = techniques.first(where: { $0.id == id }) else {
            throw ProductionKnowledgeErrorV1.invalidValue(path: "technique", reason: "choose A, B or C")
        }
        var ids = technique.techniqueEntryIDs
        if id != "A" { ids += technique.sharedUnitIDs }
        return try ids.map(read)
    }

    public func search(_ query: String, offset: Int = 0) throws -> [Record] {
        guard offset >= 0 else {
            throw ProductionKnowledgeErrorV1.invalidValue(path: "offset", reason: "must be nonnegative")
        }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return Array(records.filter { record in
            let heading = "\(record.id) \(record.kind) \(record.title)".lowercased()
            return terms.allSatisfy { heading.contains($0) || record.text.lowercased().contains($0) }
        }.sorted { $0.id < $1.id }.dropFirst(offset).prefix(25))
    }

    func validate() throws {
        func require(_ condition: Bool, _ reason: String) throws {
            guard condition else {
                throw ProductionKnowledgeErrorV1.invalidValue(path: "archive.3.4", reason: reason)
            }
        }
        try require(schemaVersion == "production-knowledge-archive.v1" && sourceVersion == "3.4",
                    "unsupported archive schema or source version")
        try require(archiveSHA256 == "4827d6da3df7654434bceac3e143ec7172f18833a7a45c693fcf55c68a2cd012",
                    "wrong source archive")
        try require(!license.isEmpty && !precedence.isEmpty, "missing license or adaptation")
        try require(Set(records.map(\.id)).count == records.count, "duplicate record IDs")
        for (kind, count) in [("section", 297), ("unit", 682), ("blueprint", 42),
                              ("runbook", 10), ("table", 59), ("template", 21), ("format-spec", 4)] {
            try require(records.filter { $0.kind == kind }.count == count, "incomplete \(kind) inventory")
        }
        let sections = Dictionary(uniqueKeysWithValues: records.filter { $0.kind == "section" }.map { ($0.id, $0) })
        for record in records {
            _ = try read(record.id)
            try require(record.source.archiveSHA256 == archiveSHA256, "wrong record source")
            if record.kind == "section" {
                try require(record.sha256 == record.source.sha256, "section no longer matches supplied bytes")
            } else if record.kind == "unit" {
                guard let section = sections[record.sectionID],
                      let start = record.startCharacter, let end = record.endCharacter else {
                    throw ProductionKnowledgeErrorV1.invalidValue(path: record.id, reason: "missing unit bounds")
                }
                let scalars = Array(section.text.unicodeScalars)
                try require(start >= 0 && end >= start && end <= scalars.count, "invalid Unicode unit bounds")
                let exact = String(String.UnicodeScalarView(scalars[start..<end]))
                try require(record.text == exact, "unit differs from exact source range")
            } else if record.kind != "format-spec" {
                try require(sections[record.sectionID] != nil, "missing governing section")
            }
        }
        try require(Set(techniques.map(\.id)) == ["A", "B", "C"] && techniques.count == 3,
                    "incomplete technique menu")
        for technique in techniques {
            for id in technique.techniqueEntryIDs + technique.sharedUnitIDs { _ = try read(id) }
        }
    }
}

extension ProductionKnowledgeLoaderV1 {
    public func loadArchive34() throws -> ProductionKnowledgeArchive34 {
        struct Manifest: Decodable {
            let schemaVersion: String
            let sourceVersion: String
            let path: String
            let sha256: String
        }
        let directory = rootURL.appendingPathComponent("archives")
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.schemaVersion == "production-knowledge-archive-manifest.v1",
              manifest.sourceVersion == "3.4", manifest.path == "ai-film-production-3.4.json" else {
            throw ProductionKnowledgeErrorV1.invalidValue(path: "archives/manifest.json", reason: "unsupported archive")
        }
        let data = try Data(contentsOf: directory.appendingPathComponent(manifest.path))
        let actual = FileDigest.sha256(of: data)
        guard actual == manifest.sha256 else {
            throw ProductionKnowledgeErrorV1.digestMismatch(path: manifest.path, expected: manifest.sha256, actual: actual)
        }
        let archive = try JSONDecoder().decode(ProductionKnowledgeArchive34.self, from: data)
        try archive.validate()
        return archive
    }
}

extension EngineProductionKnowledgeResourcesV1 {
    public static func loadArchive34() throws -> ProductionKnowledgeArchive34 {
        try ProductionKnowledgeLoaderV1(rootURL: rootURL()).loadArchive34()
    }
}
