import Foundation

extension EditorViewModel {
    @discardableResult
    func continueProductionPhase(_ phase: String, diagnostic: String? = nil) -> Bool {
        let detail = diagnostic.map { "\nApproval diagnostic: \($0)" } ?? ""
        let started = agentService.sendWorkOrder(
            .init(title: "Continue \(PhaseDisplay.label(phase))", systemImage: "play",
                  prompt: "Continue the current \(phase) phase using its required workflow. Resolve its missing evidence and present the result for review. Never approve it yourself.\(detail)",
                  phase: phase), direction: "", mentions: [])
        if started { didStartProductionTurn() }
        else { showsAgentActivity = true }
        return started
    }
}
