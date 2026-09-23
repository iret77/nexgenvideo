import Foundation

@Observable
@MainActor
final class MireloCapabilityCatalog {
    static let shared = MireloCapabilityCatalog()

    private(set) var account: MireloAccount?
    private(set) var models: [MireloModel] = []
    private(set) var observedAt: Date?

    func publish(account: MireloAccount, models: [MireloModel], observedAt: Date) {
        self.account = account
        self.models = models
        self.observedAt = observedAt
    }

    func clear() {
        account = nil
        models = []
        observedAt = nil
    }

    func model(id: String) -> MireloModel? {
        models.first { $0.id == id || "mirelo/\($0.id)" == id }
    }
}

enum MireloCatalogDiscovery {
    enum Result: Sendable {
        case inactive
        case success(account: MireloAccount, models: [MireloModel], entries: [CatalogEntry])
        case authenticationFailure(String)
        case transientFailure(String)
        case unavailableFailure(String)
    }

    static func discover(_ provider: GenerationProvider) async -> Result {
        guard provider == .mirelo,
              let key = ProviderKeychain.load(.mirelo),
              !key.isEmpty else { return .inactive }
        do {
            let client = MireloClient(apiKey: key)
            async let account = client.account()
            async let models = client.models()
            let (resolvedAccount, resolvedModels) = try await (account, models)
            let executable = resolvedModels.filter {
                $0.status != "deprecated" && !supportedOperationIDs($0).isEmpty
            }
            return .success(
                account: resolvedAccount,
                models: executable,
                entries: executable.compactMap(catalogEntry)
            )
        } catch let error as MireloHTTPError {
            if error.status == 401 || error.status == 403 {
                return .authenticationFailure(
                    "Mirelo rejected the saved API key. Replace it and test the connection."
                )
            }
            if error.retryable == true || error.status == 429 || error.status.map({ $0 >= 500 }) == true {
                return .transientFailure(error.localizedDescription)
            }
            return .unavailableFailure(error.localizedDescription)
        } catch {
            return .transientFailure("Mirelo discovery failed: \(error.localizedDescription)")
        }
    }

    static func catalogEntry(_ model: MireloModel) -> CatalogEntry? {
        let supported = supportedOperationIDs(model)
        let inputs = [
            supported.contains(MireloOperation.textToSFX.rawValue) ? "text" : nil,
            supported.contains(MireloOperation.videoToSFX.rawValue) ? "video" : nil,
            supported.contains(MireloOperation.extend.rawValue)
                || supported.contains(MireloOperation.inpaint.rawValue) ? "audio" : nil,
        ].compactMap { $0 }
        guard !inputs.isEmpty else { return nil }
        let ranges = [
            supported.contains(MireloOperation.textToSFX.rawValue)
                ? model.operations[MireloOperation.textToSFX.rawValue]?.durationMs : nil,
            supported.contains(MireloOperation.videoToSFX.rawValue)
                ? model.operations[MireloOperation.videoToSFX.rawValue]?.durationMs : nil,
        ].compactMap { $0 }
        let minimum = ranges.compactMap(\.min).min().map { max(1, Int(ceil(Double($0) / 1_000))) }
        let maximum = ranges.compactMap(\.max).max().map { max(1, Int(floor(Double($0) / 1_000))) }
        return CatalogEntry(
            id: "mirelo/\(model.id)",
            kind: .audio,
            displayName: "Mirelo \(model.id)",
            allowedEndpoints: supported.sorted(),
            responseShape: .audio,
            uiCapabilities: .audio(AudioCaps(
                category: "sfx",
                voices: nil,
                defaultVoice: nil,
                supportsLyrics: false,
                supportsInstrumental: false,
                supportsStyleInstructions: false,
                durations: nil,
                minPromptLength: inputs.contains("text") ? 1 : 0,
                inputs: inputs,
                promptLabel: "Describe the sound",
                minSeconds: minimum,
                maxSeconds: maximum
            )),
            audioPricing: .perSecond(rate: model.creditsPerSecond),
            offers: [ProviderOffer(
                provider: .mirelo,
                transport: .api,
                providerRef: model.id,
                costPerCall: nil
            )]
        )
    }

    static func supportedOperationIDs(_ model: MireloModel) -> Set<String> {
        guard model.status != "deprecated", !model.formats.isEmpty else { return [] }
        return Set(model.operations.compactMap { name, limits in
            guard limits.numVariants != nil,
                  let operation = MireloOperation(rawValue: name) else { return nil }
            switch operation {
            case .textToSFX, .videoToSFX:
                return limits.durationMs == nil ? nil : name
            case .extend:
                return limits.appendDurationMs == nil ? nil : name
            case .inpaint:
                return limits.regionStartMs == nil || limits.regionWidthMs == nil
                    ? nil : name
            case .audioToMIDI:
                return nil
            }
        })
    }
}
