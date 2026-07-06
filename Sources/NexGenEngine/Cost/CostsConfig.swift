import Foundation

/// Render phase — `render/costs.py::Phase = Literal["preview", "final"]`.
public enum Phase: String, Codable, Sendable, CaseIterable {
    case preview
    case final
}

/// Per-model pricing. Port of `render/costs.py::ModelPricing`.
///
/// `eurPerSecond` is the fallback (worst-case-resolution) price, used both when
/// `eurPerSecondByResolution` is unset and when the resolution passed to a call
/// is unknown. `minDurationS` is the provider minimum per render call (shots
/// under it get billed up to the minimum). `eurPerSecondByResolution`
/// (v0.11.5) overrides `eurPerSecond` for known resolutions.
public struct ModelPricing: Codable, Sendable, Equatable {
    public var eurPerSecond: Double
    public var maxDurationS: Double
    public var defaultRatio: String
    public var minDurationS: Double
    public var eurPerSecondByResolution: [String: Double]?

    public init(
        eurPerSecond: Double, maxDurationS: Double, defaultRatio: String,
        minDurationS: Double = 0.0, eurPerSecondByResolution: [String: Double]? = nil
    ) {
        self.eurPerSecond = eurPerSecond
        self.maxDurationS = maxDurationS
        self.defaultRatio = defaultRatio
        self.minDurationS = minDurationS
        self.eurPerSecondByResolution = eurPerSecondByResolution
    }

    private enum CodingKeys: String, CodingKey {
        case eurPerSecond = "eur_per_second"
        case maxDurationS = "max_duration_s"
        case defaultRatio = "default_ratio"
        case minDurationS = "min_duration_s"
        case eurPerSecondByResolution = "eur_per_second_by_resolution"
    }

    /// Mirrors `load_costs`' per-field coercion: `min_duration_s` defaults to 0
    /// when absent, `eur_per_second_by_resolution` stays nil when the key is
    /// absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eurPerSecond = try container.decode(Double.self, forKey: .eurPerSecond)
        maxDurationS = try container.decode(Double.self, forKey: .maxDurationS)
        defaultRatio = try container.decode(String.self, forKey: .defaultRatio)
        minDurationS = try container.decodeIfPresent(Double.self, forKey: .minDurationS) ?? 0.0
        eurPerSecondByResolution =
            try container.decodeIfPresent([String: Double].self, forKey: .eurPerSecondByResolution)
    }

    /// Port of `ModelPricing.eur_per_second_for`. Known resolution → exact
    /// price; unknown resolution or nil → `eurPerSecond` (worst-case fallback).
    public func eurPerSecond(for resolution: String?) -> Double {
        if let resolution, let table = eurPerSecondByResolution, let price = table[resolution] {
            return price
        }
        return eurPerSecond
    }
}

/// Cost-guard thresholds (v0.11.5). Port of `render/costs.py::CostGuard`.
public struct CostGuard: Codable, Sendable, Equatable {
    public var confirmThresholdEur: Double
    public var projectWideBudget: Bool

    public init(confirmThresholdEur: Double = 10.0, projectWideBudget: Bool = true) {
        self.confirmThresholdEur = confirmThresholdEur
        self.projectWideBudget = projectWideBudget
    }

    private enum CodingKeys: String, CodingKey {
        case confirmThresholdEur = "confirm_threshold_eur"
        case projectWideBudget = "project_wide_budget"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confirmThresholdEur =
            try container.decodeIfPresent(Double.self, forKey: .confirmThresholdEur) ?? 10.0
        projectWideBudget =
            try container.decodeIfPresent(Bool.self, forKey: .projectWideBudget) ?? true
    }
}

/// The full cost configuration. Port of `render/costs.py::CostsConfig`.
public struct CostsConfig: Sendable, Equatable {
    public var pricing: [String: ModelPricing]
    public var modelMap: [String: String]
    public var defaults: [String: String]
    public var overlapPreS: Double
    public var overlapPostS: Double
    public var pollingIntervalS: Int
    public var pollingTimeoutS: Int
    public var costGuard: CostGuard

    public init(
        pricing: [String: ModelPricing], modelMap: [String: String], defaults: [String: String],
        overlapPreS: Double, overlapPostS: Double, pollingIntervalS: Int, pollingTimeoutS: Int,
        costGuard: CostGuard = CostGuard()
    ) {
        self.pricing = pricing
        self.modelMap = modelMap
        self.defaults = defaults
        self.overlapPreS = overlapPreS
        self.overlapPostS = overlapPostS
        self.pollingIntervalS = pollingIntervalS
        self.pollingTimeoutS = pollingTimeoutS
        self.costGuard = costGuard
    }

    public enum ConfigError: Swift.Error, Sendable, Equatable {
        /// Port of `CostsConfig.price`'s `KeyError`.
        case noPricingForModel(String)
    }

    /// Port of `CostsConfig.runway_model_for` — provider-aware render-model
    /// resolution.
    ///
    /// Bug 24 (v0.11.6): previously `model_suggestion → model_map` was applied
    /// across the provider branch, so a fal shot with
    /// `model_suggestion=SEEDANCE_2_0` was assigned `"seedance2"` (the Runway
    /// legacy price 0.10 EUR/s) even though the dispatcher actually renders via
    /// the fal endpoint (0.25–0.68 EUR/s) — the estimate came out 2.5–6x too
    /// low. New logic: for a FAL shot take `defaults[phase]` when it is a fal
    /// model, else fall back to `fal:bytedance/seedance-2.0/fast`, ignoring
    /// `model_suggestion` entirely (model_map only knows Runway models). For a
    /// RUNWAY (legacy) shot the old path stands: `model_suggestion → model_map`,
    /// else `defaults[phase]`.
    public func runwayModel(for shot: Shot, phase: Phase) -> String {
        if shot.sceneVideoProvider == .fal {
            let phaseDefault = defaults[phase.rawValue] ?? ""
            if phaseDefault.hasPrefix("fal:") {
                return phaseDefault
            }
            // defaults points at a Runway model (old config) → safe fal fallback.
            return "fal:bytedance/seedance-2.0/fast"
        }

        // Runway path (legacy). Python keys the lookup by the enum *value*
        // (`shot.model_suggestion.value`), so the raw string ("seedance-2.0")
        // is matched against model_map — reproduced here via rawValue.
        if let suggestion = shot.modelSuggestion?.rawValue, let mapped = modelMap[suggestion] {
            return mapped
        }
        // Under a Runway provider, defaults must not point at a fal model —
        // if it does, fall back to a known Runway slug.
        let runwayDefault = defaults[phase.rawValue] ?? ""
        if runwayDefault.hasPrefix("fal:") {
            return "seedance2"  // proven Runway-legacy default
        }
        return runwayDefault
    }

    /// Port of `CostsConfig.price`. Throws `noPricingForModel` when the model
    /// is absent (Python raises `KeyError`).
    public func price(_ runwayModel: String) throws -> ModelPricing {
        guard let pricing = pricing[runwayModel] else {
            throw ConfigError.noPricingForModel(runwayModel)
        }
        return pricing
    }
}
