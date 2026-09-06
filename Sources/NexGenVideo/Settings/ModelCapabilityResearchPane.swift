import NexGenEngine
import SwiftUI

struct ModelCapabilityResearchPane: View {
    private var catalog = ModelCatalog.shared
    @Bindable private var research = ModelCapabilityResearchController.shared

    @State private var expandedRecordIDs = Set<String>()
    @State private var pendingDeleteRecordID: String?

    private var researchTargets: [ModelCapabilityResearchTargetV1] {
        guard research.recordsLoaded else { return [] }
        return ModelCapabilityResearchTargetBuilder.targets(
            catalog: catalog,
            records: research.records,
            corpus: CatalogCapabilityRuntime.corpus
        )
    }

    var body: some View {
        Group {
            if !researchTargets.isEmpty || !research.records.isEmpty
                || research.phase != .idle {
                capabilityResearchSection
            }
        }
        .task { research.start() }
        .confirmationDialog(
            "Delete local specifications?",
            isPresented: Binding(
                get: { pendingDeleteRecordID != nil },
                set: { if !$0 { pendingDeleteRecordID = nil } }
            ),
            presenting: pendingDeleteRecordID
        ) { recordID in
            Button("Delete specifications", role: .destructive) {
                if let record = research.records.first(where: { $0.id == recordID }) {
                    research.delete(record)
                }
                pendingDeleteRecordID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The accepted evidence will be removed. A superseded predecessor is restored when available.")
        }
    }

    private var capabilityResearchSection: some View {
        SettingsSection(
            "Capability Research",
            subtitle: "Verify uncertain model specifications with official sources in an isolated Claude session."
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                if let statusMessage = research.statusMessage {
                    SettingsNotice(
                        text: statusMessage,
                        systemImage: statusSystemImage,
                        tone: statusTone
                    )
                }
                if research.phase == .checking || research.phase == .researching {
                    researchProgress
                }
                if let review = research.review {
                    reviewCard(review)
                }
                ForEach(researchTargets) { target in
                    researchTargetCard(target)
                }
                if !research.records.isEmpty {
                    localKnowledge
                }
            }
        }
    }

    private var statusSystemImage: String {
        switch research.phase {
        case .accepted: return "checkmark.circle.fill"
        case .unavailable: return "lock.slash"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "info.circle"
        }
    }

    private var statusTone: SettingsTone {
        switch research.phase {
        case .accepted: return .success
        case .unavailable: return .warning
        case .failed: return .error
        default: return .neutral
        }
    }

    private var researchProgress: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(research.phase == .checking
                            ? "Checking Claude web capability"
                            : "Researching official specifications")
                            .interfaceFont(
                                size: AppTheme.Typography.ui,
                                weight: AppTheme.FontWeight.medium
                            )
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(research.phase == .checking
                            ? "Verifying the installed CLI and its isolated runtime tools."
                            : "Only WebSearch and WebFetch can run. The session cannot access projects or generation providers.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: AppTheme.Spacing.lg)
                    Button("Cancel") { research.cancelResearch() }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                }
                if research.phase == .researching {
                    ProgressView(value: research.progress)
                        .progressViewStyle(.linear)
                }
            }
            .padding(AppTheme.Spacing.lgXl)
        }
    }

    private func researchTargetCard(_ target: ModelCapabilityResearchTargetV1) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ViewThatFits(in: .horizontal) {
                    targetHeader(target, horizontal: true)
                    targetHeader(target, horizontal: false)
                }
                identityDetails(target)
                SettingsNotice(
                    text: "Research is optional. The current safe fallback remains available until you accept verified fields.",
                    systemImage: "lock.shield",
                    tone: .neutral
                )
            }
            .padding(AppTheme.Spacing.lgXl)
        }
    }

    private func targetHeader(
        _ target: ModelCapabilityResearchTargetV1,
        horizontal: Bool
    ) -> some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: AppTheme.Spacing.lgXl))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: AppTheme.Spacing.md))
        return layout {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(target.modelDisplayName)
                        .interfaceFont(
                            size: AppTheme.Typography.section,
                            weight: AppTheme.FontWeight.semibold
                        )
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    SettingsStatusBadge(text: triggerLabel(target.trigger), tone: .warning)
                }
                Text(fallbackDescription(target.fallback))
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if horizontal { Spacer(minLength: AppTheme.Spacing.lg) }
            Button("Research specs with Claude") {
                research.startResearch(target)
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .disabled(research.phase == .checking
                || research.phase == .researching
                || research.phase == .saving)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func identityDetails(_ target: ModelCapabilityResearchTargetV1) -> some View {
        let binding = target.request.binding
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                identityCell(
                    "Family",
                    target.usesSyntheticIdentity ? "Unclassified" : binding.identity.familyID.rawValue
                )
                identityCell(
                    "Variant · Version",
                    target.usesSyntheticIdentity
                        ? "Provider-bound · Unversioned"
                        : "\(binding.identity.variantID.rawValue) · \(binding.identity.versionID.rawValue)"
                )
                identityCell("Provider · Endpoint", "\(providerName(binding.providerID)) · \(binding.endpointID)")
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                identityCell(
                    "Family · Variant · Version",
                    target.usesSyntheticIdentity
                        ? "Unclassified · Provider-bound · Unversioned"
                        : "\(binding.identity.familyID.rawValue) · \(binding.identity.variantID.rawValue) · \(binding.identity.versionID.rawValue)"
                )
                identityCell("Provider · Endpoint", "\(providerName(binding.providerID)) · \(binding.endpointID)")
            }
        }
    }

    private func identityCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label.uppercased())
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(value)
                .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.smMd)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.dim))
        )
    }

    private func reviewCard(_ review: ModelCapabilityResearchReviewV1) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Review researched specifications")
                            .interfaceFont(
                                size: AppTheme.Typography.section,
                                weight: AppTheme.FontWeight.semibold
                            )
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text("\(review.applicableFieldCount) proven fields can be accepted. Conflicts keep the fallback.")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    Spacer(minLength: AppTheme.Spacing.lg)
                    SettingsStatusBadge(text: "Review", tone: .neutral)
                }
                sourceList(review)
                VStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(review.fields, id: \.fieldID) { field in
                        reviewField(field)
                    }
                }
                HStack(spacing: AppTheme.Spacing.sm) {
                    Spacer(minLength: AppTheme.Spacing.none)
                    Button("Decline") { research.declineReview() }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                    Button("Accept \(research.selectedFieldIDs.count) proven fields") {
                        research.acceptReview()
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(research.selectedFieldIDs.isEmpty || research.phase == .saving)
                }
            }
            .padding(AppTheme.Spacing.lgXl)
        }
    }

    private func sourceList(_ review: ModelCapabilityResearchReviewV1) -> some View {
        let sources = uniqueSources(review)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Official sources")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.primaryColor)
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    if let rawURL = source.sourceURL, let url = URL(string: rawURL) {
                        Link(destination: url) {
                            Label(source.sourceTitle, systemImage: "arrow.up.right")
                        }
                        .interfaceFont(size: AppTheme.Typography.ui)
                    } else {
                        Text(source.sourceTitle)
                            .interfaceFont(size: AppTheme.Typography.ui)
                    }
                    Text("\(evidenceKindLabel(source.kind)) · \(confidenceLabel(source.confidence)) · observed \(source.observedAt)")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.dim))
        )
    }

    private func reviewField(_ field: ModelCapabilityResearchFieldDiffV1) -> some View {
        let canAccept = reviewFieldCanApply(field)
        return HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Toggle("", isOn: Binding(
                get: { research.selectedFieldIDs.contains(field.fieldID) },
                set: { selected in
                    if selected {
                        research.selectedFieldIDs.insert(field.fieldID)
                    } else {
                        research.selectedFieldIDs.remove(field.fieldID)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!canAccept)
            .accessibilityLabel("Accept \(field.fieldID)")
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                    Text(field.fieldID)
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium, design: .monospaced)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Spacer(minLength: AppTheme.Spacing.md)
                    SettingsStatusBadge(
                        text: decisionLabel(field.decision),
                        tone: decisionTone(field.decision)
                    )
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                        valueColumn("Current fallback", field.current)
                        valueColumn("Candidate", field.candidate)
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        valueColumn("Current fallback", field.current)
                        valueColumn("Candidate", field.candidate)
                    }
                }
                if let evidence = field.evidence.max(by: { $0.confidence < $1.confidence }) {
                    Text("\(evidenceKindLabel(evidence.kind)) · \(confidenceLabel(evidence.confidence)) · \(evidence.observedAt) · \(field.semantics.rawValue.replacingOccurrences(of: "_", with: " "))")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.dim))
        )
    }

    private func valueColumn(
        _ label: String,
        _ value: ModelCapabilityResearchFieldValueV1?
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label)
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(ModelCapabilityResearchFieldPresentation.string(value))
                .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localKnowledge: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Local capability knowledge")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text("Stored in Application Support and never in a project.")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            ForEach(research.records) { record in
                localRecordCard(record)
            }
        }
    }

    private func localRecordCard(_ record: ModelCapabilityResearchOverlayRecordV1) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ViewThatFits(in: .horizontal) {
                    recordHeader(record, horizontal: true)
                    recordHeader(record, horizontal: false)
                }
                if expandedRecordIDs.contains(record.id) {
                    VStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(record.fieldIDs, id: \.self) { fieldID in
                            recordField(record, fieldID: fieldID)
                        }
                    }
                }
            }
            .padding(AppTheme.Spacing.lgXl)
        }
    }

    private func recordHeader(
        _ record: ModelCapabilityResearchOverlayRecordV1,
        horizontal: Bool
    ) -> some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: AppTheme.Spacing.md))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: AppTheme.Spacing.md))
        return layout {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(ModelRegistry.displayName(for: record.binding.catalogModelID))
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    SettingsStatusBadge(
                        text: recordStatusLabel(record.status),
                        tone: recordStatusTone(record.status)
                    )
                }
                Text("\(scopeLabel(record.scope)) · \(record.fieldIDs.count) fields · accepted \(record.acceptedAt) · \(providerName(record.binding.providerID))")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if horizontal { Spacer(minLength: AppTheme.Spacing.md) }
            recordActions(record)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recordActions(_ record: ModelCapabilityResearchOverlayRecordV1) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button(expandedRecordIDs.contains(record.id) ? "Hide comparison" : "Compare") {
                if expandedRecordIDs.contains(record.id) {
                    expandedRecordIDs.remove(record.id)
                } else {
                    expandedRecordIDs.insert(record.id)
                }
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            switch record.status {
            case .active:
                Button("Disable") { research.disable(record) }
                    .buttonStyle(.capsule(.secondary, size: .regular))
            case .disabled, .archived, .superseded:
                Button("Enable") { research.enable(record) }
                    .buttonStyle(.capsule(.secondary, size: .regular))
            }
            if record.status != .archived {
                Button("Archive") { research.archive(record) }
                    .buttonStyle(.capsule(.secondary, size: .regular))
            }
            if let target = ModelCapabilityResearchTargetBuilder.target(
                for: record,
                catalog: catalog,
                corpus: CatalogCapabilityRuntime.corpus
            ) {
                Button("Update") { research.startResearch(target) }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(research.phase == .checking
                        || research.phase == .researching
                        || research.phase == .saving)
            }
            Button("Delete…") { pendingDeleteRecordID = record.id }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .foregroundStyle(AppTheme.Status.errorColor)
        }
    }

    private func recordField(
        _ record: ModelCapabilityResearchOverlayRecordV1,
        fieldID: String
    ) -> some View {
        let current = ModelCapabilityResearchTargetBuilder.target(
            for: record,
            catalog: catalog,
            corpus: CatalogCapabilityRuntime.corpus
        ).flatMap {
            ModelCapabilityResearchFieldPresentation.resolvedValue(
                fieldID: fieldID,
                fields: $0.fallback.fields
            )
        }
        let stored = ModelCapabilityResearchFieldPresentation.candidateValue(
            fieldID: fieldID,
            fields: record.fields
        )
        let effective = effectiveValue(record, fieldID: fieldID)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(fieldID)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium, design: .monospaced)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: AppTheme.Spacing.md)
                SettingsStatusBadge(
                    text: recordFieldStatus(record, stored: stored, effective: effective),
                    tone: record.status == .active ? .neutral : .warning
                )
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    valueColumn("Current bundled value", current)
                    valueColumn("Stored evidence", stored)
                    valueColumn("Effective value", effective)
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    valueColumn("Current bundled value", current)
                    valueColumn("Stored evidence", stored)
                    valueColumn("Effective value", effective)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.dim))
        )
    }

    private func effectiveValue(
        _ record: ModelCapabilityResearchOverlayRecordV1,
        fieldID: String
    ) -> ModelCapabilityResearchFieldValueV1? {
        catalog.offeringCapabilitiesByModelID[record.binding.catalogModelID]?
            .first(where: {
                $0.offering.providerID == record.binding.providerID
                    && $0.offering.offeringID == record.binding.offeringID
                    && $0.offering.endpointID == record.binding.endpointID
            })
            .flatMap {
                ModelCapabilityResearchFieldPresentation.resolvedValue(
                    fieldID: fieldID,
                    fields: $0.effective.fields
                )
            }
    }

    private func recordFieldStatus(
        _ record: ModelCapabilityResearchOverlayRecordV1,
        stored: ModelCapabilityResearchFieldValueV1?,
        effective: ModelCapabilityResearchFieldValueV1?
    ) -> String {
        guard record.status == .active else { return "Inactive" }
        return stored == effective ? "Effective" : "Fallback retained"
    }

    private func uniqueSources(
        _ review: ModelCapabilityResearchReviewV1
    ) -> [CapabilityEvidenceV1] {
        var keys = Set<String>()
        return review.fields.flatMap(\.evidence).filter { evidence in
            let key = "\(evidence.sourceURL ?? "")\u{1f}\(evidence.sourceTitle)"
            return keys.insert(key).inserted
        }
    }

    private func reviewFieldCanApply(_ field: ModelCapabilityResearchFieldDiffV1) -> Bool {
        field.decision == .applicable || field.decision == .unchanged
    }

    private func triggerLabel(_ trigger: ModelCapabilityResearchTriggerV1) -> String {
        switch trigger {
        case .inheritedProfile: return "Inherited profile"
        case .defensiveProfile: return "Defensive profile"
        case .staleEvidence: return "Evidence outdated"
        case .conflictingEvidence: return "Evidence conflict"
        }
    }

    private func fallbackDescription(_ profile: ResolvedCapabilityProfileV1) -> String {
        if let identity = profile.resolvedIdentity {
            return "Using \(identity.familyID.rawValue) \(identity.variantID.rawValue) \(identity.versionID.rawValue) until newer evidence is accepted."
        }
        return "Using \(profile.defensiveProfileID ?? "the safe modality profile") until exact evidence is accepted."
    }

    private func providerName(_ providerID: String) -> String {
        GenerationProvider(rawValue: providerID)?.displayName ?? providerID
    }

    private func confidenceLabel(_ confidence: Double) -> String {
        String(format: "%.0f%% confidence", confidence * 100)
    }

    private func evidenceKindLabel(_ kind: CapabilityEvidenceKindV1) -> String {
        switch kind {
        case .documentedAPI: return "Documented API"
        case .providerSchema: return "Provider schema"
        case .empirical: return "Observed"
        case .inferred: return "Inferred"
        case .defensive: return "Defensive"
        }
    }

    private func decisionLabel(_ decision: ModelCapabilityResearchDiffDecisionV1) -> String {
        switch decision {
        case .applicable: return "Apply"
        case .unchanged: return "Confirm"
        case .conflictKeepsFallback: return "Keep fallback"
        case .insufficientEvidence: return "Unproven"
        case .curatedPreferred: return "Bundled wins"
        case .endpointBounded: return "Endpoint limit"
        case .endpointUnavailable: return "Other endpoint"
        case .inactive: return "Inactive"
        }
    }

    private func decisionTone(_ decision: ModelCapabilityResearchDiffDecisionV1) -> SettingsTone {
        switch decision {
        case .applicable, .unchanged: return .success
        case .conflictKeepsFallback, .insufficientEvidence, .endpointBounded,
             .endpointUnavailable: return .warning
        case .curatedPreferred, .inactive: return .neutral
        }
    }

    private func recordStatusLabel(
        _ status: ModelCapabilityResearchOverlayStatusV1
    ) -> String {
        switch status {
        case .active: return "Active"
        case .disabled: return "Disabled"
        case .archived: return "Archived"
        case .superseded: return "Superseded"
        }
    }

    private func recordStatusTone(
        _ status: ModelCapabilityResearchOverlayStatusV1
    ) -> SettingsTone {
        switch status {
        case .active: return .success
        case .disabled, .archived, .superseded: return .neutral
        }
    }

    private func scopeLabel(_ scope: ModelCapabilityResearchScopeV1) -> String {
        scope == .intrinsic ? "Model" : "Provider endpoint"
    }
}
