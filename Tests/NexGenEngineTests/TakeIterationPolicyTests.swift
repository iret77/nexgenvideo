import Testing
@testable import NexGenEngine

@Suite("Observed iteration policy")
struct TakeIterationPolicyTests {
    private func batch(_ id: String, axis: String = "identity", clean: Bool = false, channel: String? = nil) -> [TakeIterationRollV1] {
        (0..<4).map { .init(eventID: "\(id)-\($0)", promptRevisionID: id, reviewed: true, rejectedAxis: axis,
            cleanRewrite: clean, controlChannel: channel) }
    }

    @Test func individualRollsAndUnobservedOutputsDoNotBecomeFailedIterations() throws {
        let policy = TakeIterationPolicyV1()
        let two = Array(batch("one").prefix(2))
        let first = try TakeIterationAssessmentV1.assess(rolls: two, currentPromptRevisionID: "one", policy: policy)
        #expect(first.completedFailedIterations == 0)
        #expect(first.recommendation == .rerollAvailable)
        let pending = two + [.init(eventID: "p3", promptRevisionID: "one", reviewed: false, rejectedAxis: nil),
            .init(eventID: "p4", promptRevisionID: "one", reviewed: false, rejectedAxis: nil)]
        let second = try TakeIterationAssessmentV1.assess(rolls: pending, currentPromptRevisionID: "one", policy: policy)
        #expect(second.recommendation == .reviewPending)
        #expect(second.completedFailedIterations == 0)
        #expect(throws: (any Error).self) {
            try TakeIterationAssessmentV1.assess(rolls: [.init(eventID: "unseen", promptRevisionID: "one", reviewed: false, rejectedAxis: "identity")],
                currentPromptRevisionID: "one", policy: policy)
        }
    }

    @Test func rewriteAndModelLimitNeedSeparateObservedIterationsAndChannels() throws {
        let failures = batch("a") + batch("b") + batch("c")
        let base = try TakeIterationAssessmentV1.assess(rolls: failures, currentPromptRevisionID: "c", policy: .init())
        #expect(base.recommendation == .cleanRewriteAndChannelChange)
        let oneChannel = failures + batch("d", clean: true, channel: "reference") + batch("e", clean: true, channel: "reference")
        #expect(try TakeIterationAssessmentV1.assess(rolls: oneChannel, currentPromptRevisionID: "e", policy: .init()).recommendation != .modelLimitEligible)
        let twoChannels = failures + batch("d", clean: true, channel: "reference") + batch("e", clean: true, channel: "model")
        #expect(try TakeIterationAssessmentV1.assess(rolls: twoChannels, currentPromptRevisionID: "e", policy: .init()).recommendation == .modelLimitEligible)
        let differentAxis = failures + batch("d", clean: true, channel: "reference") + batch("e", axis: "camera", clean: true, channel: "model")
        #expect(try TakeIterationAssessmentV1.assess(rolls: differentAxis, currentPromptRevisionID: "e", policy: .init()).recommendation != .modelLimitEligible)
    }

    @Test func duplicateEventsCannotInventABatchAndAnAcceptedCandidateBreaksFailure() throws {
        let roll = batch("a")[0]
        #expect(throws: (any Error).self) { try TakeIterationAssessmentV1.assess(rolls: Array(repeating: roll, count: 4), currentPromptRevisionID: "a", policy: .init()) }
        let rolls = Array(batch("a").prefix(3)) + [.init(eventID: "good", promptRevisionID: "a", reviewed: true, rejectedAxis: nil)]
        let result = try TakeIterationAssessmentV1.assess(rolls: rolls, currentPromptRevisionID: "a", policy: .init())
        #expect(result.recommendation == .chooseCandidate)
        #expect(result.completedFailedIterations == 0)
    }
}
