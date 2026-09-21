import Foundation

enum LUTStoreError: LocalizedError {
    case noFile(String), invalid(String)
    var errorDescription: String? {
        switch self {
        case .noFile(let path): "No file at path: \(path)"
        case .invalid(let name): "Not a valid .cube 3D LUT: \(name)"
        }
    }
}

/// Parses .cube 3D LUT files into CIColorCube-ready RGBA float data.
/// Cached by path + mtime, like AlphaVideoNormalizer's tag scheme.
enum LUTLoader {

    private static let minimumDimension = 2
    private static let maximumDimension = 65
    private static let inputChannels = 3
    private static let outputChannels = 4
    private static let maximumEntryCount = maximumDimension * maximumDimension * maximumDimension
    private static let maximumOutputBytes = maximumEntryCount * outputChannels * MemoryLayout<Float>.size
    private static let maximumSourceBytes = maximumOutputBytes * 16

    struct CubeLUT {
        let dimension: Int
        let data: Data
    }

    /// Validates a .cube file and copies it into the project's LUT storage so it survives
    /// saves and moves (project packages drop unknown files). Returns the stored path.
    /// Shared by the agent (apply_color) and the inspector's LUT picker.
    static func store(path: String, projectId: String?) throws -> String {
        let sourceURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw LUTStoreError.noFile(sourceURL.path) }
        guard load(path: sourceURL.path) != nil else { throw LUTStoreError.invalid(sourceURL.lastPathComponent) }
        let lutDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NexGenVideo/luts/\(projectId ?? "default")", isDirectory: true)
        try FileManager.default.createDirectory(at: lutDir, withIntermediateDirectories: true)
        let dest = lutDir.appendingPathComponent(sourceURL.lastPathComponent)
        if sourceURL.standardizedFileURL == dest.standardizedFileURL { return dest.path }   // already stored
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return dest.path
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (mtime: Date, lut: CubeLUT)] = [:]

    static func load(path: String) -> CubeLUT? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast

        lock.lock()
        if let entry = cache[path], entry.mtime == mtime {
            lock.unlock()
            return entry.lut
        }
        lock.unlock()

        guard sourceSize(atPath: path) <= maximumSourceBytes,
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let lut = parse(text) else { return nil }

        lock.lock()
        cache[path] = (mtime, lut)
        lock.unlock()
        return lut
    }

    static func parse(_ text: String) -> CubeLUT? {
        guard text.utf8.count <= maximumSourceBytes else { return nil }

        var dimension = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []
        var expectedValueCount: Int?
        var sawDimension = false
        var sawDomainMin = false
        var sawDomainMax = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first else { continue }
            switch first.uppercased() {
            case "TITLE", "LUT_1D_SIZE":
                if first.uppercased() == "LUT_1D_SIZE" { return nil }
            case "LUT_3D_SIZE":
                guard !sawDimension, parts.count == 2,
                      let parsedDimension = Int(parts[1]),
                      (minimumDimension...maximumDimension).contains(parsedDimension) else { return nil }
                dimension = parsedDimension
                expectedValueCount = dimension * dimension * dimension * inputChannels
                sawDimension = true
            case "DOMAIN_MIN":
                guard !sawDomainMin, let parsed = finiteTriple(parts) else { return nil }
                domainMin = parsed
                sawDomainMin = true
            case "DOMAIN_MAX":
                guard !sawDomainMax, let parsed = finiteTriple(parts) else { return nil }
                domainMax = parsed
                sawDomainMax = true
            default:
                guard sawDimension, let expectedValueCount, let rgb = finiteTriple(parts),
                      values.count <= expectedValueCount - inputChannels else { return nil }
                values.append(contentsOf: rgb)
            }
        }

        guard sawDimension, let expectedValueCount,
              values.count == expectedValueCount,
              zip(domainMin, domainMax).allSatisfy({ $0 < $1 }) else { return nil }

        // Normalize domain and pack as RGBA float32 (r fastest), as CIColorCube expects.
        var rgba = [Float]()
        rgba.reserveCapacity(dimension * dimension * dimension * outputChannels)
        for i in 0..<(values.count / inputChannels) {
            for c in 0..<inputChannels {
                let span = max(0.0001, domainMax[c] - domainMin[c])
                rgba.append(min(1, max(0, (values[i * inputChannels + c] - domainMin[c]) / span)))
            }
            rgba.append(1)
        }
        return CubeLUT(dimension: dimension, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    private static func finiteTriple(_ parts: [Substring]) -> [Float]? {
        guard parts.count == inputChannels + 1 else { return nil }
        let values = parts.dropFirst().compactMap { Float($0) }
        guard values.count == inputChannels, values.allSatisfy(\.isFinite) else { return nil }
        return values
    }

    private static func sourceSize(atPath path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)
            .flatMap { $0 }?.intValue ?? .max
    }
}
