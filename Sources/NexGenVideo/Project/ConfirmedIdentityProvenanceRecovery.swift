import Foundation
import NexGenEngine

struct ConfirmedIdentityProvenanceRecoveryStatus: Sendable, Equatable {
    let affectedTargets: [String]
    let discardedTargets: [String]
    let eligible: Bool
    let blocker: String?

    static let action = "recover_confirmed_identity_provenance"
}

enum ConfirmedIdentityProvenanceRecovery {
    static let minimumPackVersion = SemanticVersion(
        major: 0,
        minor: 5,
        patch: 9
    )

    enum RecoveryError: LocalizedError, Sendable, Equatable {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): message
            }
        }
    }

    static func status(
        dataRoot: URL
    ) -> ConfirmedIdentityProvenanceRecoveryStatus? {
        guard let engineStatus = ConfirmedIdentityAssetStoreV1
            .legacyRecoveryStatus(dataRoot: dataRoot) else {
            return nil
        }
        if !engineStatus.eligible {
            return ConfirmedIdentityProvenanceRecoveryStatus(
                affectedTargets: engineStatus.affectedTargets,
                discardedTargets: engineStatus.discardedTargets,
                eligible: false,
                blocker: engineStatus.blocker
            )
        }
        do {
            try requireCompatibleBinding(dataRoot: dataRoot)
            return ConfirmedIdentityProvenanceRecoveryStatus(
                affectedTargets: engineStatus.affectedTargets,
                discardedTargets: engineStatus.discardedTargets,
                eligible: true,
                blocker: nil
            )
        } catch {
            return ConfirmedIdentityProvenanceRecoveryStatus(
                affectedTargets: engineStatus.affectedTargets,
                discardedTargets: engineStatus.discardedTargets,
                eligible: false,
                blocker: error.localizedDescription
            )
        }
    }

    static func requireCompatibleBinding(dataRoot: URL) throws {
        let home = FrameInventory.projectHome(of: dataRoot)
        guard case .bound(let binding) = ProjectPluginSettings
            .bindingResolution(projectURL: home) else {
            throw RecoveryError.unavailable(
                "Update this project to Music Video workflow 0.5.9 or later before recovering identity references."
            )
        }
        try requireCompatibleBinding(binding)
    }

    static func requireCompatibleBinding(
        _ binding: ProjectPackBinding?
    ) throws {
        guard let binding,
              binding.id == "musicvideo",
              let version = SemanticVersion(binding.version),
              version >= minimumPackVersion else {
            throw RecoveryError.unavailable(
                "Update this project to Music Video workflow 0.5.9 or later before recovering identity references."
            )
        }
    }

    @MainActor
    static func recover(
        editor: EditorViewModel,
        projectDir: URL
    ) async throws -> ConfirmedIdentityLegacyRecoveryResultV1 {
        guard let dataRoot = DataRootResolver.dataRoot(of: projectDir),
              let workingRoot = editor.workingRoot,
              workingRoot.standardizedFileURL.resolvingSymlinksInPath()
                == projectDir.standardizedFileURL.resolvingSymlinksInPath(),
              let key = editor.openWorkingCopyKey else {
            throw RecoveryError.unavailable(
                "Reopen the project before recovering identity references."
            )
        }
        let recoveryStatus = status(dataRoot: dataRoot)
        guard recoveryStatus?.eligible == true else {
            throw RecoveryError.unavailable(
                recoveryStatus?.blocker
                    ?? "No recoverable identity-reference provenance was found."
            )
        }
        guard let mutationID = editor.pipelinePhaseRunCoordinator.beginMutation(
            projectRoot: dataRoot,
            label: "Recover identity-reference provenance"
        ) else {
            let active = editor.pipelinePhaseRunCoordinator.runningPhase(
                projectRoot: dataRoot
            ) ?? "pipeline work"
            throw RecoveryError.unavailable(
                "Wait for \(active) to finish before recovering identity references."
            )
        }
        defer {
            editor.pipelinePhaseRunCoordinator.endMutation(
                projectRoot: dataRoot,
                id: mutationID
            )
        }
        _ = try ProjectPackGate.requireLiveMutation(
            projectURL: projectDir,
            declaredPack: editor.declaredPluginName,
            declaredBinding: editor.declaredPluginBinding
        )
        try requireCompatibleBinding(editor.declaredPluginBinding)
        try ProjectWorkingCopy.markDirty(key: key)
        guard let result = try await Task.detached(priority: .utility, operation: {
            try ConfirmedIdentityAssetStoreV1.recoverLegacyAdoptions(
                dataRoot: dataRoot
            )
        }).value else {
            throw RecoveryError.unavailable(
                "No recoverable identity-reference provenance was found."
            )
        }
        guard editor.pipelinePhaseRunCoordinator.holdsMutation(
            projectRoot: dataRoot,
            id: mutationID
        ) else {
            throw RecoveryError.unavailable(
                "Identity-reference recovery lost its mutation reservation. Reopen the project before retrying."
            )
        }
        return result
    }
}
