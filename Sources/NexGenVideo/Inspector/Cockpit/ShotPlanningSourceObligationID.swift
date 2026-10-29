import NexGenEngine

enum ShotPlanningSourceObligationID {
    nonisolated static func make(preferred: String?, obligations: [ShotPlanningDraftV1.Obligation]) -> String {
        if let preferred, obligations.contains(where: { $0.id == preferred && $0.kind == .sourceFootage && $0.required }) {
            return preferred
        }
        let used = Set(obligations.map(\.id))
        var candidate = "source-footage"
        var suffix = 2
        while used.contains(candidate) {
            candidate = "source-footage-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
