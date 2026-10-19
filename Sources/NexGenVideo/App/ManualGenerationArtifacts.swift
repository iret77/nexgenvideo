import Foundation

enum ManualGenerationArtifacts {
    nonisolated static func save(name: String, package: GenerationPackageV1, submit: Data, input: Data? = nil,
                     output: Data, directory: URL) throws -> [String: String] {
        let files: [(String, Data)] = [("package", try GenerationPackageV1.canonicalData(package)),
            ("submit", submit), ("output", output)] + (input.map { [("input", $0)] } ?? [])
        var references: [String: String] = [:]
        for (kind, bytes) in files {
            let filename = name + "." + kind + (kind == "package" || kind == "submit" ? ".json" : ".bin")
            try bytes.write(to: directory.appendingPathComponent(filename), options: .atomic)
            references[kind] = directory.lastPathComponent + "/" + filename
        }
        return references
    }
}
