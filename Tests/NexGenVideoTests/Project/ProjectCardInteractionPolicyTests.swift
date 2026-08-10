import Testing
@testable import NexGenVideo

@Suite("Project card interaction policy")
struct ProjectCardInteractionPolicyTests {
    @Test func eachControlHasOneExclusiveAction() {
        #expect(ProjectCardInteractionPolicy.action(for: .primary, isAccessible: true) == .open)
        #expect(ProjectCardInteractionPolicy.action(for: .primary, isAccessible: false) == .none)
        #expect(
            ProjectCardInteractionPolicy.action(for: .removal, isAccessible: true)
                == .confirmDeletion
        )
        #expect(
            ProjectCardInteractionPolicy.action(for: .removal, isAccessible: false)
                == .removeFromRecents
        )
    }
}
