import AppKit
import NexGenEngine

@MainActor
enum ProductionV2PreRenderAcceptance {
    static func references(context: ProductionPlanningAcceptanceFixture.Context,
                           driver: ProductionVisualSourcesDriver, additionalAudioPath: String? = nil, requiresNativeLook: Bool = true) async throws {
        let root = context.dataRoot, window = driver.window
        try await ProductionPlanningAcceptanceFixture.writeBible(in: context)
        let draft = try await Task.detached {
            try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: PlanningWriterIO.storyboard(dataRoot: root))
        }.value
        let design = try await Task.detached { try YAMLArtifactStore(dataRoot: root).load(ProductionDesign.self, at: PipelineLayout.productionDesignFile) }.value
        guard let reference = design.refs.first else { throw GateBlocked("The real Production Design has no image candidate.") }
        var assets = Set(draft.shots.compactMap { $0.source?.path }).sorted().map {
            ["path": $0, "modality": "video", "allowed_use_ids": []] as [String: Any]
        }
        if let additionalAudioPath { assets.append(["path": additionalAudioPath, "modality": "audio", "allowed_use_ids": []]) }
        assets.append(["path": reference.path, "modality": "image", "allowed_use_ids": [CoreReferenceSemanticJobIDV1.styleReference]])
        try await ProductionPlanningAcceptanceFixture.run("prepare_production_assets", args: ["assets": assets], in: context)
        try await ProductionV2PlanningAcceptance.selectPhase("bible", context: context, driver: driver)
        try await driver.segment("bible.section", title: "Shot references", titles: BiblePanelView.Section.allCases.map(\.rawValue), in: window)
        let snapshot = try await Task.detached { try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: root) }.value
        if requiresNativeLook {
            guard let shot = snapshot.draft.shots.first,
                  let candidate = snapshot.eligibleAssets(shotID: shot.shotID, obligationID: "look").first(where: { $0.path == reference.path }),
                  snapshot.resolutions.allSatisfy({ $0.shotID != shot.shotID || $0.obligationID != "look" }) else {
                throw GateBlocked("The style obligation was preselected or has no genuine prepared Design image.")
            }
            let prefix = shot.shotID + ".look"
            try await driver.wait("native reference choices loaded") { driver.text("production.references.asset." + prefix, in: window) != nil }
            guard driver.state("production.references.confirm." + prefix, in: window) == false else {
                throw GateBlocked("An unselected style reference can already be confirmed.")
            }
            let title = [URL(fileURLWithPath: candidate.path).lastPathComponent,
                candidate.viewID?.replacingOccurrences(of: "_", with: " ")].compactMap { $0 }.joined(separator: " · ")
            try await driver.picker("production.references.asset." + prefix, title: title, expected: candidate.id, in: window)
            try await driver.wait("real reference preview bound") { driver.text("production.references.preview." + prefix, in: window) == candidate.sha256 }
            try await driver.reveal("production.references.preview." + prefix, in: window)
            try driver.visible(["production.references.preview." + prefix], in: window)
            try driver.capture("reference-candidate-inspected", target: window)
            try await driver.click("production.references.confirm." + prefix, in: window)
            try await driver.wait("native reference choice committed", seconds: 30) {
                driver.state("production.references.confirm." + prefix, in: window) == false
                    && driver.text("production.references.asset." + prefix, in: window) == candidate.id
            }
            let saved = try await Task.detached { try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: root) }.value
            guard let choice = saved.resolutions.first(where: { $0.shotID == shot.shotID && $0.obligationID == "look" }),
                  case .asset(let id, _) = choice.outcome, id == candidate.id, saved.fingerprint != snapshot.fingerprint else {
                throw GateBlocked("The native reference confirmation did not publish its exact candidate binding.")
            }
            try driver.record("native shot reference", fields: ["shotID": shot.shotID, "assetID": candidate.id, "sha256": candidate.sha256])
        } else {
            guard snapshot.draft.shots.allSatisfy({ $0.sourceMode == .imported && $0.obligations.isEmpty }) else {
                throw GateBlocked("The private source path may omit reference selection only for actual imported shots without obligations.")
            }
            try driver.capture("imported-reference-plan", target: window)
            try driver.record("imported reference contract", fields: ["shotIDs": snapshot.draft.shots.map(\.shotID),
                "requiredObligations": [], "nativeReferenceSelectionClaim": false])
        }
        try await ProductionV2PlanningAcceptance.approve("bible", artifact: PipelineLayout.bibleFile,
            next: "shotlist", context: context, driver: driver)
    }

    static func review(context: ProductionPlanningAcceptanceFixture.Context,
                       driver: ProductionVisualSourcesDriver) async throws {
        let root = context.dataRoot, window = driver.window
        let projection = try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: root) }.value
        try await ProductionV2PlanningAcceptance.selectPhase("shotlist", context: context, driver: driver)
        try await driver.wait("canonical production plan visible") { driver.state("production.plan.workspace", in: window) != nil }
        try driver.capture("resolved-production-plan", target: window)
        try await ProductionV2PlanningAcceptance.approve("shotlist", artifact: ProductionPlanProjectionV1.versionPath(projection.header.revision),
            next: "sanity", context: context, driver: driver)
        try await ProductionPlanningAcceptanceFixture.prepareImportedSanity(in: context)
        try await ProductionV2PlanningAcceptance.selectPhase("sanity", context: context, driver: driver)
        try await ProductionV2PlanningAcceptance.approve("sanity", artifact: PipelineLayout.sanityReportFile,
            next: "frames", context: context, driver: driver)
        guard projection.shots.allSatisfy({ projection.requiredFrameRoles(for: $0.id).isEmpty }) else {
            throw GateBlocked("The reference-only fixture unexpectedly requires generated keyframes; it may not skip them.")
        }
        try await ProductionPlanningAcceptanceFixture.prepareEmptyFrames(in: context)
        let frames = try await Task.detached { try ProductionPlanFramesV1.requireCurrent(projection: projection, dataRoot: root) }.value
        guard frames.shots.isEmpty else { throw GateBlocked("The approved reference-only route unexpectedly generated a keyframe.") }
        try await ProductionV2PlanningAcceptance.selectPhase("frames", context: context, driver: driver)
        try await ProductionV2PlanningAcceptance.approve("frames", artifact: PipelineLayout.framesManifestFile,
            next: "render_review", context: context, driver: driver)
        try driver.record("reference-only Frames contract", fields: ["requiredFrameRoles": [], "manifestShots": frames.shots.count,
            "nativePhaseApproval": true, "generatedFrameClaim": false])
        try await ProductionV2PlanningAcceptance.selectPhase("render_review", context: context, driver: driver)
        try await driver.wait("current pre-render inputs displayed", seconds: 60) {
            driver.text("render-review.workspace", in: window)?.isEmpty == false
        }
        let snapshot = try await PipelineRenderReviewWriter.capture(editor: context.editor)
        guard driver.text("render-review.workspace", in: window) == snapshot.fingerprint,
              snapshot.shots.map(\.shotID) == projection.shots.map(\.id) else { throw GateBlocked("The visible input review does not match the current plan.") }
        for shot in snapshot.shots {
            guard driver.state("render-review.inspected." + shot.shotID, in: window) == false else { throw GateBlocked("A shot was already inspected before native input.") }
            let visibleRefs = shot.sourceInput.map { [$0] } ?? shot.review.conditioning.filter {
                ["png", "jpg", "jpeg", "webp", "mov", "mp4"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
            }
            guard !visibleRefs.isEmpty else { throw GateBlocked("A shot has no visible real source or conditioning input.") }
            for ref in visibleRefs {
                let id = "render-review.preview." + shot.shotID + "." + ref.id
                try await driver.reveal(id, in: window)
                guard driver.text(id, in: window) == ref.sha256 else { throw GateBlocked("The visible pre-render media differs from its exact source.") }
                try driver.visible([id], in: window)
                try driver.capture("pre-render-input-" + shot.shotID, target: window)
            }
            if let prompt = shot.compiledPrompt {
                let id = "render-review.final-direction." + shot.shotID
                try await ProductionNativeReadingAcceptance.read(id, expected: prompt, driver: driver)
            }
            try await driver.click("render-review.inspected." + shot.shotID, in: window, enabled: false)
            try await driver.wait("shot inputs explicitly inspected") { driver.state("render-review.inspected." + shot.shotID, in: window) == true }
        }
        try await driver.click("render-review.record-native", in: window)
        try await driver.wait("native input inspection persisted", seconds: 30) {
            (try? PipelineRenderReviewWriter.loadIfPresent(dataRoot: root))?.reviewer.kind == .nativeUser
        }
        let review = try await Task.detached {
            guard let value = try PipelineRenderReviewWriter.loadIfPresent(dataRoot: root) else { throw GateBlocked("The input inspection was not saved.") }
            try PipelineRenderReviewWriter.requireCurrent(value, root)
            return value
        }.value
        guard review.shots == snapshot.shots.map(\.review) else { throw GateBlocked("The saved inspection changed its reviewed inputs.") }
        try driver.record("native pre-render inspection", fields: ["fingerprint": snapshot.fingerprint,
            "shotIDs": snapshot.shots.map(\.shotID), "reviewEvidenceSHA256": review.reviewEvidence.sha256])
        try await ProductionV2PlanningAcceptance.approve("render_review", artifact: RenderReviewV1.currentPath,
            next: "render", context: context, driver: driver)
    }
}
