import Foundation

public struct TakeIterationPolicyV1: Codable, Sendable, Equatable {
    public var rollsPerPrompt: Int
    public var failuresBeforeRewrite: Int
    public var cleanFailuresBeforeModelLimit: Int
    public var channelsBeforeModelLimit: Int
    public var iterationsBeforeSimplification: Int

    public init(rollsPerPrompt: Int = 4, failuresBeforeRewrite: Int = 3,
                cleanFailuresBeforeModelLimit: Int = 2, channelsBeforeModelLimit: Int = 2,
                iterationsBeforeSimplification: Int = 10) {
        self.rollsPerPrompt = rollsPerPrompt
        self.failuresBeforeRewrite = failuresBeforeRewrite
        self.cleanFailuresBeforeModelLimit = cleanFailuresBeforeModelLimit
        self.channelsBeforeModelLimit = channelsBeforeModelLimit
        self.iterationsBeforeSimplification = iterationsBeforeSimplification
    }

    public func validate() throws {
        guard rollsPerPrompt > 0, failuresBeforeRewrite > 0, cleanFailuresBeforeModelLimit >= 2,
              channelsBeforeModelLimit >= 2, iterationsBeforeSimplification >= failuresBeforeRewrite else {
            throw TakeIterationError.invalid("Iteration limits must be positive. A model-limit claim needs at least two clean failures across two control channels.")
        }
    }
}

public enum TakeIterationError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let reason): reason } }
}

public struct TakeIterationRollV1: Sendable, Equatable {
    public let eventID: String
    public let promptRevisionID: String
    public let reviewed: Bool
    public let rejectedAxis: String?
    public let cleanRewrite: Bool
    public let controlChannel: String?

    public init(eventID: String, promptRevisionID: String, reviewed: Bool, rejectedAxis: String?,
                cleanRewrite: Bool = false, controlChannel: String? = nil) {
        self.eventID = eventID
        self.promptRevisionID = promptRevisionID
        self.reviewed = reviewed
        self.rejectedAxis = rejectedAxis
        self.cleanRewrite = cleanRewrite
        self.controlChannel = controlChannel
    }
}

public struct TakeIterationAssessmentV1: Codable, Sendable, Equatable {
    public struct Iteration: Codable, Sendable, Equatable {
        public let promptRevisionID: String
        public let rolls: Int
        public let pendingReviews: Int
        public let hasAcceptedCandidate: Bool
        public let failedAxis: String?
        public let cleanRewrite: Bool
        public let controlChannel: String?
    }
    public enum Recommendation: String, Codable, Sendable {
        case reviewPending, chooseCandidate, rerollAvailable, reviseOneVariable
        case cleanRewriteAndChannelChange, modelLimitEligible, simplifyShot
    }
    public let iterations: [Iteration]
    public let recommendation: Recommendation
    public let axis: String?
    public let completedFailedIterations: Int

    public static func assess(rolls: [TakeIterationRollV1], currentPromptRevisionID: String,
                              policy: TakeIterationPolicyV1) throws -> Self {
        try policy.validate()
        guard Set(rolls.map(\.eventID)).count == rolls.count,
              rolls.allSatisfy({ !$0.eventID.isEmpty && !$0.promptRevisionID.isEmpty
                  && ($0.reviewed || $0.rejectedAxis == nil)
                  && ($0.rejectedAxis == nil || ["identity", "continuity", "timing", "camera", "audio", "style"].contains($0.rejectedAxis ?? ""))
                  && (!$0.cleanRewrite || $0.controlChannel?.isEmpty == false) }) else {
            throw TakeIterationError.invalid("Iteration evidence has duplicate events or unobserved failure claims.")
        }
        var order: [String] = []
        var groups: [String: [TakeIterationRollV1]] = [:]
        for roll in rolls {
            if groups[roll.promptRevisionID] == nil { order.append(roll.promptRevisionID) }
            groups[roll.promptRevisionID, default: []].append(roll)
        }
        let iterations: [Iteration] = order.map { id in
            let group = groups[id] ?? []
            let pending = group.filter { !$0.reviewed }.count
            let accepted = group.contains { $0.reviewed && $0.rejectedAxis == nil }
            let axes = Set(group.compactMap(\.rejectedAxis))
            let failed = group.count >= policy.rollsPerPrompt && pending == 0 && !accepted && axes.count == 1
            let channels = Set(group.compactMap(\.controlChannel))
            return Iteration(promptRevisionID: id, rolls: group.count, pendingReviews: pending,
                hasAcceptedCandidate: accepted, failedAxis: failed ? axes.first : nil,
                cleanRewrite: group.allSatisfy(\.cleanRewrite) && channels.count == 1,
                controlChannel: channels.count == 1 ? channels.first : nil)
        }
        let current = iterations.first { $0.promptRevisionID == currentPromptRevisionID }
        let axis = current?.failedAxis ?? iterations.last(where: { $0.failedAxis != nil })?.failedAxis
        let failures = iterations.filter { $0.failedAxis != nil && $0.failedAxis == axis }
        let clean = failures.filter(\.cleanRewrite)
        let cleanChannels = Set(clean.compactMap(\.controlChannel))
        let recommendation: Recommendation
        if current?.hasAcceptedCandidate == true { recommendation = .chooseCandidate }
        else if (current?.pendingReviews ?? 0) > 0 { recommendation = .reviewPending }
        else if iterations.count >= policy.iterationsBeforeSimplification { recommendation = .simplifyShot }
        else if clean.count >= policy.cleanFailuresBeforeModelLimit && cleanChannels.count >= policy.channelsBeforeModelLimit {
            recommendation = .modelLimitEligible
        } else if failures.count >= policy.failuresBeforeRewrite { recommendation = .cleanRewriteAndChannelChange }
        else if (current?.rolls ?? 0) >= policy.rollsPerPrompt { recommendation = .reviseOneVariable }
        else { recommendation = .rerollAvailable }
        return Self(iterations: iterations, recommendation: recommendation, axis: axis, completedFailedIterations: failures.count)
    }
}
