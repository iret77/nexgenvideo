import BpyRuntimeProtocol

nonisolated enum BpyJSONValidation {
    static func validate(_ file: BpyRuntimeFile, checking: @escaping () throws -> Void = {}) throws {
        try BpyRuntimeJSONValidation.validate(file, checking: checking)
    }
}
