public enum BpyOutputContract {
    public static func acceptsNames(_ names: [String]) -> Bool {
        let folded = names.map { $0.lowercased() }
        return Set(folded).count == names.count && names.allSatisfy { name in
            let bytes = Array(name.utf8)
            func alnum(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
            return (1...128).contains(bytes.count) && bytes.first.map(alnum) == true
                && bytes.allSatisfy { alnum($0) || [45, 46, 95].contains($0) }
        }
    }

    public static func acceptsWorkerNames(_ names: [String]) -> Bool {
        acceptsNames(names) && !names.contains { $0.lowercased() == "verification.json" }
    }

    public static func acceptsOutputs(_ outputs: [BpyOutputDescriptor], fileLimit: Int, byteLimit: UInt64) -> Bool {
        guard outputs.count <= min(256, fileLimit), acceptsNames(outputs.map(\.name)),
              outputs.contains(where: { $0.name == "scene.blend" }),
              outputs.contains(where: { $0.name == "verification.json" }) else { return false }
        var total: UInt64 = 0
        for output in outputs {
            guard let separator = output.name.lastIndex(of: ".") else { return false }
            let expected: String
            switch output.name[output.name.index(after: separator)...].lowercased() {
            case "blend": expected = "application/x-blender"
            case "png": expected = "image/png"
            case "json": expected = "application/json"
            default: return false
            }
            guard output.mediaType == expected, output.byteCount <= UInt64(Int.max),
                  total <= byteLimit, output.byteCount <= byteLimit - total else { return false }
            total += output.byteCount
        }
        return true
    }

    public static func permitsHostManifest(workerFileCount: Int, workerBytes: UInt64, manifestBytes: UInt64,
                                           fileLimit: Int, byteLimit: UInt64) -> Bool {
        workerFileCount >= 0 && workerFileCount < min(256, fileLimit)
            && workerBytes <= byteLimit && manifestBytes <= byteLimit - workerBytes
    }
}
