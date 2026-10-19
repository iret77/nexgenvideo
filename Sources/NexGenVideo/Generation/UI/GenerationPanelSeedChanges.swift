struct GenerationPanelSeedChanges {
    enum Field: Hashable { case type, videoModel, imageModel, audioModel, aspect, resolution }
    private var pending: [Field: String] = [:]

    init(before: [Field: String] = [:], after: [Field: String] = [:]) {
        pending = after.filter { before[$0.key] != $0.value }
    }

    mutating func consume(_ field: Field, value: String, currentValue: String? = nil) -> Bool {
        if let currentValue, value != currentValue { return true }
        return pending.removeValue(forKey: field) == value
    }
}
