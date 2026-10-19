import Foundation
import NexGenEngine

enum LUTStoreError: LocalizedError {
    case noFile(String), invalid(String)
    var errorDescription: String? {
        switch self {
        case .noFile(let path): "The LUT ‘\((path as NSString).lastPathComponent)’ is offline. Relink or remove it before saving or exporting."
        case .invalid: "The LUT is unreadable or its stored bytes changed. Choose a valid .cube LUT, or remove the effect."
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
        let domainMin: SIMD3<Float>
        let domainMax: SIMD3<Float>

        init(dimension: Int, data: Data, domainMin: SIMD3<Float> = .zero,
             domainMax: SIMD3<Float> = SIMD3(repeating: 1)) {
            self.dimension = dimension; self.data = data
            self.domainMin = domainMin; self.domainMax = domainMax
        }
    }

    static func store(path: String, projectRoot: URL) throws -> String {
        let source: URL
        if ProjectEffectResources.isPortable(path) {
            source = try ProjectEffectResources.url(for: path, projectRoot: projectRoot)
        } else {
            source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let bytes = try validatedBytes(at: source)
        if ProjectEffectResources.isPortable(path) { try register(bytes, path: path) }
        let relative = ProjectEffectResources.directory + "/" + FileDigest.sha256(of: bytes) + ".cube"
        let destination = try ProjectEffectResources.url(for: relative, projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == bytes else { throw LUTStoreError.invalid(destination.lastPathComponent) }
        } else {
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".lut-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try bytes.write(to: temporary, options: .atomic)
            do { try FileManager.default.linkItem(at: temporary, to: destination) }
            catch {
                guard FileManager.default.fileExists(atPath: destination.path),
                      try Data(contentsOf: destination) == bytes else { throw error }
            }
        }
        try register(bytes, path: relative)
        return relative
    }

    static func validatedBytes(at url: URL) throws -> Data {
        guard let bytes = sourceBytes(atPath: url.path) else { throw LUTStoreError.noFile(url.lastPathComponent) }
        guard let text = String(data: bytes, encoding: .utf8), parse(text) != nil else { throw LUTStoreError.invalid(url.lastPathComponent) }
        return bytes
    }

    static func register(_ bytes: Data, path: String) throws {
        guard ProjectEffectResources.isPortable(path),
              URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent == FileDigest.sha256(of: bytes),
              let text = String(data: bytes, encoding: .utf8), let lut = parse(text) else { throw LUTStoreError.invalid(path) }
        lock.lock()
        portableCache[path] = lut
        lock.unlock()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var portableCache: [String: CubeLUT] = [:]
    nonisolated(unsafe) private static var cache: [String: (mtime: Date, lut: CubeLUT)] = [:]

    static func load(path: String) -> CubeLUT? {
        if ProjectEffectResources.isPortable(path) {
            lock.lock(); defer { lock.unlock() }
            return portableCache[path]
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast

        lock.lock()
        if let entry = cache[path], entry.mtime == mtime {
            lock.unlock()
            return entry.lut
        }
        lock.unlock()

        guard let text = sourceText(atPath: path),
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
                guard !sawDomainMin, let parsed = finiteTriple(parts.dropFirst()) else { return nil }
                domainMin = parsed
                sawDomainMin = true
            case "DOMAIN_MAX":
                guard !sawDomainMax, let parsed = finiteTriple(parts.dropFirst()) else { return nil }
                domainMax = parsed
                sawDomainMax = true
            default:
                guard sawDimension, let expectedValueCount, let rgb = finiteTriple(parts[...]),
                      values.count <= expectedValueCount - inputChannels else { return nil }
                values.append(contentsOf: rgb)
            }
        }

        guard sawDimension, let expectedValueCount,
              values.count == expectedValueCount,
              zip(domainMin, domainMax).allSatisfy({ $0 < $1 && ($1 - $0).isFinite }) else { return nil }

        // Cube domains describe sample coordinates; table entries remain unscaled outputs.
        var rgba = [Float]()
        rgba.reserveCapacity(dimension * dimension * dimension * outputChannels)
        for i in 0..<(values.count / inputChannels) {
            rgba.append(contentsOf: values[(i * inputChannels)..<((i + 1) * inputChannels)])
            rgba.append(1)
        }
        return CubeLUT(dimension: dimension, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) },
            domainMin: SIMD3(domainMin[0], domainMin[1], domainMin[2]),
            domainMax: SIMD3(domainMax[0], domainMax[1], domainMax[2]))
    }

    private static func finiteTriple(_ parts: ArraySlice<Substring>) -> [Float]? {
        guard parts.count == inputChannels else { return nil }
        let values = parts.compactMap { Float($0) }
        guard values.count == inputChannels, values.allSatisfy(\.isFinite) else { return nil }
        return values
    }

    private static func sourceText(atPath path: String) -> String? {
        sourceBytes(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func sourceBytes(atPath path: String) -> Data? {
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: maximumSourceBytes + 1),
                  data.count <= maximumSourceBytes else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
