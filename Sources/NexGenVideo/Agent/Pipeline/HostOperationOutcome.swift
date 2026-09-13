import Foundation

struct HostOperationOutcome: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable, Equatable {
        case rejectedBeforeWrite = "rejected_before_write"
        case persistedButStructurallyInvalid = "persisted_but_structurally_invalid"
        case validatedAwaitingReview = "validated_awaiting_review"
        case approvedCurrent = "approved_current"
        case staleAfterLineageChange = "stale_after_lineage_change"
    }

    static let schemaVersion = "host-operation-outcome/v1"

    let schema: String
    let state: State
    let phase: String
    let diagnostic: String?

    init(state: State, phase: String, diagnostic: String?) {
        self.schema = Self.schemaVersion
        self.state = state
        self.phase = phase
        self.diagnostic = diagnostic
    }

    var userSummary: String {
        let label = PhaseDisplay.label(phase)
        switch state {
        case .rejectedBeforeWrite:
            return String(localized: "\(label) was not saved.")
        case .persistedButStructurallyInvalid:
            return String(localized: "\(label) was saved but is not ready for review.")
        case .validatedAwaitingReview:
            return String(localized: "\(label) is saved and ready for review.")
        case .approvedCurrent:
            return String(localized: "\(label) is approved.")
        case .staleAfterLineageChange:
            return String(localized: "\(label) approval is out of date.")
        }
    }

    func encodedText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decode(text: String) throws -> Self {
        let data = Data(text.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: Set(["schema", "state", "phase", "diagnostic"])),
              object["schema"] as? String == schemaVersion,
              let phase = object["phase"] as? String,
              !phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Invalid host operation outcome."
            ))
        }
        let outcome = try JSONDecoder().decode(Self.self, from: data)
        guard outcome.schema == schemaVersion else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Unsupported host operation outcome."
            ))
        }
        return outcome
    }

    static func acceptsResult(from toolName: String) -> Bool {
        let firstPartyPrefix = "mcp__nexgen__"
        let rawName = toolName.hasPrefix(firstPartyPrefix)
            ? String(toolName.dropFirst(firstPartyPrefix.count)) : toolName
        guard let tool = ToolName(rawValue: rawName) else { return false }
        switch tool {
        case .writeAnalysisInterpretation, .writeBrief, .writeProductionDesign,
             .writeTreatment, .writeStoryboard, .writeBible, .writeShotlist,
             .writePhaseExtension, .runSanity, .saveFrameAudit, .runPhase,
             .recordRender, .approveGate, .setGateState, .rewind:
            return true
        default:
            return false
        }
    }
}

struct HostOperationFailure: Error, LocalizedError, Sendable, Equatable {
    let outcome: HostOperationOutcome

    var errorDescription: String? {
        outcome.diagnostic ?? outcome.userSummary
    }
}
