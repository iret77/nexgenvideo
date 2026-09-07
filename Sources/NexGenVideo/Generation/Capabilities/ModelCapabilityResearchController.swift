import Foundation
import NexGenEngine

struct ModelCapabilityResearchTargetV1: Identifiable, Sendable, Equatable {
    let id: String
    let modelDisplayName: String
    let request: ModelCapabilityResearchRequestV1
    let fallback: ResolvedCapabilityProfileV1
    let usesSyntheticIdentity: Bool

    var trigger: ModelCapabilityResearchTriggerV1 { request.trigger }
}

enum ModelCapabilityResearchIdentityPolicy {
    static func identity(
        profile: ResolvedCapabilityProfileV1,
        offering: CapabilityOfferingIdentityV1,
        corpus: ModelCapabilityCorpusDocument?
    ) -> (value: ModelCapabilityIdentityV1, isSynthetic: Bool) {
        if let requested = profile.requestedIdentity {
            return (requested, false)
        }
        if let entry = corpus?.inventory.first(where: {
            $0.catalogModelID == offering.catalogModelID
                && $0.provider == offering.providerID
        }), let familyID = entry.familyID,
           let variantID = entry.variantID,
           let versionID = entry.versionID {
            return (
                ModelCapabilityIdentityV1(
                    familyID: familyID,
                    variantID: variantID,
                    versionID: versionID,
                    modality: offering.modality
                ),
                false
            )
        }
        return (
            ModelCapabilityIdentityV1(
                familyID: "uncurated",
                variantID: ModelVariantID(rawValue: offering.providerID),
                versionID: ModelVersionID(rawValue: stableIdentifier(offering.catalogModelID)),
                modality: offering.modality
            ),
            true
        )
    }

    static func binding(
        profile: ResolvedCapabilityProfileV1,
        offering: CapabilityOfferingIdentityV1,
        corpus: ModelCapabilityCorpusDocument?,
        mode: String? = nil
    ) -> (value: ModelCapabilityResearchBindingV1, isSynthetic: Bool) {
        let identity = identity(profile: profile, offering: offering, corpus: corpus)
        return (
            ModelCapabilityResearchBindingV1(
                identity: identity.value,
                providerID: offering.providerID,
                offeringID: offering.offeringID,
                endpointID: offering.endpointID,
                catalogModelID: offering.catalogModelID,
                mode: mode
            ),
            identity.isSynthetic
        )
    }

    static func bindingProfile(
        _ profile: ResolvedCapabilityProfileV1,
        to identity: ModelCapabilityIdentityV1
    ) -> ResolvedCapabilityProfileV1 {
        ResolvedCapabilityProfileV1(
            requestedIdentity: identity,
            resolvedIdentity: profile.resolvedIdentity,
            defensiveProfileID: profile.defensiveProfileID,
            researchNeeded: profile.researchNeeded,
            fields: profile.fields
        )
    }

    private static func stableIdentifier(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"
        )
        if !value.isEmpty, value.count <= 180,
           value.unicodeScalars.allSatisfy(allowed.contains) {
            return value
        }
        let normalized = value.unicodeScalars.map {
            allowed.contains($0) ? String($0) : "-"
        }.joined()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let prefix = String(normalized.prefix(150)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(prefix.isEmpty ? "model" : prefix)-\(String(hash, radix: 16))"
    }
}

@MainActor
enum ModelCapabilityResearchTargetBuilder {
    static func targets(
        catalog: ModelCatalog,
        records: [ModelCapabilityResearchOverlayRecordV1],
        corpus: ModelCapabilityCorpusDocument?,
        now: Date = Date()
    ) -> [ModelCapabilityResearchTargetV1] {
        guard let corpus else { return [] }
        var result: [ModelCapabilityResearchTargetV1] = []
        var seen = Set<String>()
        for modelID in catalog.curatedOfferingCapabilitiesByModelID.keys.sorted() {
            guard GenerationProvider.canRun(modelId: modelID),
                  let capabilities = catalog.curatedOfferingCapabilitiesByModelID[modelID],
                  let capability = preferredCapability(capabilities, modelID: modelID),
                  let target = target(
                    capability: capability,
                    modelDisplayName: ModelRegistry.displayName(for: modelID),
                    records: records,
                    corpus: corpus,
                    scope: .intrinsic,
                    now: now
                  ), seen.insert(target.id).inserted else { continue }
            result.append(target)
        }
        return result
    }

    static func target(
        for record: ModelCapabilityResearchOverlayRecordV1,
        catalog: ModelCatalog,
        corpus: ModelCapabilityCorpusDocument?,
        now: Date = Date()
    ) -> ModelCapabilityResearchTargetV1? {
        guard let corpus,
              let capabilities = catalog.curatedOfferingCapabilitiesByModelID[
                record.binding.catalogModelID
              ],
              let capability = capabilities.first(where: {
                $0.offering.providerID == record.binding.providerID
                    && $0.offering.offeringID == record.binding.offeringID
                    && $0.offering.endpointID == record.binding.endpointID
              }) else { return nil }
        return target(
            capability: capability,
            modelDisplayName: ModelRegistry.displayName(for: record.binding.catalogModelID),
            records: [],
            corpus: corpus,
            scope: record.scope,
            forcedBinding: record.binding,
            forcedTrigger: .staleEvidence,
            now: now
        )
    }

    private static func preferredCapability(
        _ capabilities: [ResolvedOfferingCapabilityProfileV1],
        modelID: String
    ) -> ResolvedOfferingCapabilityProfileV1? {
        let providerID = GenerationProvider.servicing(modelId: modelID).rawValue
        return capabilities.first(where: { $0.offering.providerID == providerID })
            ?? capabilities.first
    }

    private static func target(
        capability: ResolvedOfferingCapabilityProfileV1,
        modelDisplayName: String,
        records: [ModelCapabilityResearchOverlayRecordV1],
        corpus: ModelCapabilityCorpusDocument,
        scope: ModelCapabilityResearchScopeV1,
        forcedBinding: ModelCapabilityResearchBindingV1? = nil,
        forcedTrigger: ModelCapabilityResearchTriggerV1? = nil,
        now: Date
    ) -> ModelCapabilityResearchTargetV1? {
        let resolvedBinding = forcedBinding.map {
            (value: $0, isSynthetic: $0.identity.familyID.rawValue == "uncurated")
        } ?? ModelCapabilityResearchIdentityPolicy.binding(
            profile: capability.intrinsic,
            offering: capability.offering,
            corpus: corpus
        )
        let binding = resolvedBinding.value
        let fallback = ModelCapabilityResearchIdentityPolicy.bindingProfile(
            capability.intrinsic,
            to: binding.identity
        )
        let matchingRecord = records.first {
            $0.status == .active && $0.canonicalKey == binding.canonicalKey(scope: scope)
        }
        let inventoryAvailability = corpus.inventory.first {
            $0.catalogModelID == binding.catalogModelID
                && $0.provider == binding.providerID
        }?.availability
        let trigger = forcedTrigger ?? eligibilityTrigger(
            fallback: fallback,
            record: matchingRecord,
            inventoryAvailability: inventoryAvailability,
            observedAt: corpus.observedAt,
            staleAfterDays: corpus.staleAfterDays,
            now: now
        )
        guard let trigger else { return nil }
        let allowedHosts = ModelCapabilityResearchSourceAuthority.allowedHosts(
            binding: binding,
            scope: scope
        )
        guard !allowedHosts.isEmpty else { return nil }
        let request = ModelCapabilityResearchRequestV1(
            binding: binding,
            scope: scope,
            trigger: trigger,
            fallbackResolution: resolutionClass(fallback),
            fallbackProfileID: fallbackProfileID(fallback),
            allowedSourceHosts: allowedHosts,
            observedAt: now
        )
        return ModelCapabilityResearchTargetV1(
            id: binding.canonicalKey(scope: scope),
            modelDisplayName: modelDisplayName,
            request: request,
            fallback: fallback,
            usesSyntheticIdentity: resolvedBinding.isSynthetic
        )
    }

    private static func eligibilityTrigger(
        fallback: ResolvedCapabilityProfileV1,
        record: ModelCapabilityResearchOverlayRecordV1?,
        inventoryAvailability: String?,
        observedAt: String,
        staleAfterDays: Int,
        now: Date
    ) -> ModelCapabilityResearchTriggerV1? {
        if let record {
            if ModelCapabilityResearchEvidencePolicy.hasConflict(record.allEvidence) {
                return .conflictingEvidence
            }
            let newest = record.allEvidence.compactMap {
                ModelCapabilityResearchDatePolicy.date($0.observedAt)
            }.max()
            guard let newest,
                  let deadline = ModelCapabilityResearchDatePolicy.adding(
                    days: staleAfterDays,
                    to: newest
                  ), now >= deadline else { return nil }
            return .staleEvidence
        }
        if inventoryAvailability == "stale" {
            return .staleEvidence
        }
        let resolution = resolutionClass(fallback)
        let hasConflict = allEvidence(fallback.fields).contains {
            $0.conflict?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        switch ModelCapabilityResearchEligibility.evaluate(
            resolution: resolution,
            observedAt: observedAt,
            staleAfterDays: staleAfterDays,
            now: now,
            hasConflict: hasConflict
        ) {
        case .hidden: return nil
        case .eligible(let trigger): return trigger
        }
    }

    private static func resolutionClass(
        _ profile: ResolvedCapabilityProfileV1
    ) -> CapabilityProfileResolutionV1 {
        guard profile.resolvedIdentity != nil else { return .defensive }
        return profile.requestedIdentity == profile.resolvedIdentity ? .exact : .inherited
    }

    private static func fallbackProfileID(_ profile: ResolvedCapabilityProfileV1) -> String {
        if let identity = profile.resolvedIdentity {
            return [
                identity.familyID.rawValue,
                identity.variantID.rawValue,
                identity.versionID.rawValue,
            ].joined(separator: "/")
        }
        return profile.defensiveProfileID ?? "defensive-unknown"
    }

    private static func allEvidence(
        _ fields: ResolvedCapabilityFieldsV1
    ) -> [CapabilityEvidenceV1] {
        fields.integers.values.flatMap(\.evidence)
            + fields.decimals.values.flatMap(\.evidence)
            + fields.booleans.values.flatMap(\.evidence)
            + fields.strings.values.flatMap(\.evidence)
            + fields.integerLists.values.flatMap(\.evidence)
    }
}

@Observable
@MainActor
final class ModelCapabilityResearchController {
    enum Phase: Equatable {
        case idle
        case checking
        case researching
        case review
        case saving
        case accepted
        case unavailable
        case failed
    }

    private enum RecordMutation {
        case disable
        case archive
        case enable
        case delete
    }

    typealias Probe = @Sendable (URL) throws -> ClaudeCapabilityResearchProbeV1
    typealias Research = @Sendable (
        ModelCapabilityResearchRequestV1,
        ClaudeCapabilityResearchProbeV1
    ) async throws -> ClaudeModelCapabilityResearchResultV1

    static let shared = ModelCapabilityResearchController()
    static let maximumResearchDurationSeconds: Double = 240

    private(set) var records: [ModelCapabilityResearchOverlayRecordV1] = []
    private(set) var recordsLoaded = false
    private(set) var phase: Phase = .idle
    private(set) var selectedTargetID: String?
    private(set) var statusMessage: String?
    private(set) var review: ModelCapabilityResearchReviewV1?
    private(set) var progress: Double = 0
    var selectedFieldIDs: Set<String> = []

    @ObservationIgnored private let store: ModelCapabilityResearchStore
    @ObservationIgnored private let locateExecutable: @Sendable () -> URL?
    @ObservationIgnored private let probe: Probe
    @ObservationIgnored private let research: Research
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var researchTask: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()

    init(
        store: ModelCapabilityResearchStore = ModelCapabilityResearchStore(),
        locateExecutable: @escaping @Sendable () -> URL? = {
            ClaudeCodeLocator.locateOnly()
        },
        probe: @escaping Probe = { try ClaudeCapabilityResearchProbe.run(executableURL: $0) },
        research: @escaping Research = {
            try await ClaudeModelCapabilityResearchTransport().research($0, proof: $1)
        }
    ) {
        self.store = store
        self.locateExecutable = locateExecutable
        self.probe = probe
        self.research = research
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Task { await reloadRecords(refreshCatalog: true) }
    }

    func startResearch(_ target: ModelCapabilityResearchTargetV1) {
        cancelResearch(reset: false)
        let operationID = UUID()
        self.operationID = operationID
        selectedTargetID = target.id
        statusMessage = nil
        review = nil
        selectedFieldIDs = []
        progress = 0
        phase = .checking
        let locateExecutable = self.locateExecutable
        let probe = self.probe
        let research = self.research
        researchTask = Task {
            do {
                try Task.checkCancellation()
                guard let executable = locateExecutable() else {
                    guard self.operationID == operationID else { return }
                    phase = .unavailable
                    statusMessage = "Install Claude Code and sign in before researching specifications."
                    return
                }
                let proof = try await Task.detached {
                    try probe(executable)
                }.value
                try Task.checkCancellation()
                guard self.operationID == operationID else { return }
                phase = .researching
                let progressTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, self.operationID == operationID,
                              self.phase == .researching else { return }
                        self.progress = min(
                            self.progress + 1 / Self.maximumResearchDurationSeconds,
                            1
                        )
                    }
                }
                defer { progressTask.cancel() }
                let result = try await research(target.request, proof)
                try Task.checkCancellation()
                guard self.operationID == operationID else { return }
                let review = try ModelCapabilityResearchReviewBuilder.build(
                    request: target.request,
                    candidate: result.candidate,
                    fallback: target.fallback
                )
                self.review = review
                selectedFieldIDs = review.acceptableFieldIDs
                progress = 1
                phase = .review
            } catch is CancellationError {
                guard self.operationID == operationID else { return }
                phase = .idle
                statusMessage = nil
                progress = 0
            } catch {
                guard self.operationID == operationID else { return }
                phase = availabilityFailure(error) ? .unavailable : .failed
                statusMessage = Self.message(for: error)
            }
        }
    }

    func cancelResearch(reset: Bool = true) {
        operationID = UUID()
        researchTask?.cancel()
        researchTask = nil
        guard reset else { return }
        phase = .idle
        selectedTargetID = nil
        statusMessage = nil
        review = nil
        selectedFieldIDs = []
        progress = 0
    }

    func declineReview() {
        cancelResearch()
    }

    func acceptReview() {
        guard let review, !selectedFieldIDs.isEmpty else { return }
        phase = .saving
        let selectedFieldIDs = selectedFieldIDs
        Task {
            do {
                _ = try await store.accept(review, fieldIDs: selectedFieldIDs)
                await reloadRecords(refreshCatalog: true)
                self.review = nil
                self.selectedFieldIDs = []
                phase = .accepted
                statusMessage = "Local specifications saved and applied."
            } catch {
                phase = .failed
                statusMessage = Self.message(for: error)
            }
        }
    }

    func disable(_ record: ModelCapabilityResearchOverlayRecordV1) {
        mutateRecord(.disable, recordID: record.id)
    }

    func archive(_ record: ModelCapabilityResearchOverlayRecordV1) {
        mutateRecord(.archive, recordID: record.id)
    }

    func enable(_ record: ModelCapabilityResearchOverlayRecordV1) {
        mutateRecord(.enable, recordID: record.id)
    }

    func delete(_ record: ModelCapabilityResearchOverlayRecordV1) {
        mutateRecord(.delete, recordID: record.id)
    }

    private func mutateRecord(_ mutation: RecordMutation, recordID: String) {
        Task {
            do {
                switch mutation {
                case .disable: try await store.disable(recordID)
                case .archive: try await store.archive(recordID)
                case .enable: try await store.enable(recordID)
                case .delete: try await store.delete(recordID)
                }
                await reloadRecords(refreshCatalog: true)
            } catch {
                phase = .failed
                statusMessage = Self.message(for: error)
            }
        }
    }

    private func reloadRecords(refreshCatalog: Bool = false) async {
        do {
            let snapshot = try await store.snapshot()
            records = snapshot.records
            recordsLoaded = true
            if refreshCatalog {
                ModelCatalog.shared.refreshCapabilityResolution()
            }
        } catch {
            recordsLoaded = false
            phase = .failed
            statusMessage = "Local capability knowledge could not be loaded."
        }
    }

    private func availabilityFailure(_ error: Error) -> Bool {
        guard let error = error as? ClaudeModelCapabilityResearchError else { return false }
        switch error {
        case .executableUnavailable, .probeTimedOut, .probeFailed, .unsupportedCLI,
             .missingRuntimeHandshake, .unexpectedRuntimeTools, .unexpectedMCPServer,
             .unexpectedPermissionMode, .wrongRuntimeDirectory:
            return true
        default:
            return false
        }
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? ClaudeModelCapabilityResearchError else {
            if error is ModelCapabilityResearchStoreError {
                return "Local capability knowledge could not be updated."
            }
            return "The researched specifications could not be verified. The current fallback remains active."
        }
        switch error {
        case .executableUnavailable:
            return "Install Claude Code and sign in before researching specifications."
        case .probeTimedOut, .probeFailed:
            return "Claude Code did not complete the capability check. Check the installation and try again."
        case .unsupportedCLI:
            return "Update Claude Code. This version cannot prove the required read-only web session."
        case .missingRuntimeHandshake, .unexpectedRuntimeTools, .unexpectedMCPServer,
             .unexpectedPermissionMode, .wrongRuntimeDirectory:
            return "Claude Code could not prove an isolated WebSearch and WebFetch session."
        case .timeout:
            return "Research reached its time limit. The current fallback remains active."
        default:
            return "The research result failed verification. The current fallback remains active."
        }
    }
}

enum ModelCapabilityResearchFieldPresentation {
    static func candidateValue(
        fieldID: String,
        fields: CapabilityFieldsV1
    ) -> ModelCapabilityResearchFieldValueV1? {
        if let value = fields.integers[fieldID]?.value { return .integer(value) }
        if let value = fields.decimals[fieldID]?.value { return .decimal(value) }
        if let value = fields.booleans[fieldID]?.value { return .boolean(value) }
        if let value = fields.strings[fieldID]?.value { return .stringList(value) }
        if let value = fields.integerLists[fieldID]?.value { return .integerList(value) }
        return nil
    }

    static func resolvedValue(
        fieldID: String,
        fields: ResolvedCapabilityFieldsV1
    ) -> ModelCapabilityResearchFieldValueV1? {
        if let value = fields.integers[fieldID]?.value { return .integer(value) }
        if let value = fields.decimals[fieldID]?.value { return .decimal(value) }
        if let value = fields.booleans[fieldID]?.value { return .boolean(value) }
        if let value = fields.strings[fieldID]?.value { return .stringList(value) }
        if let value = fields.integerLists[fieldID]?.value { return .integerList(value) }
        return nil
    }

    static func string(_ value: ModelCapabilityResearchFieldValueV1?) -> String {
        guard let value else { return "Not verified" }
        switch value {
        case .integer(let value): return String(value)
        case .decimal(let value): return String(format: "%g", value)
        case .boolean(let value): return value ? "Yes" : "No"
        case .stringList(let values): return values.isEmpty ? "None" : values.joined(separator: ", ")
        case .integerList(let values): return values.isEmpty
            ? "None"
            : values.map(String.init).joined(separator: ", ")
        }
    }
}
