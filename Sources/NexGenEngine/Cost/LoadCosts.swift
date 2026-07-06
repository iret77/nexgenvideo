import Foundation

/// The on-disk `costs.yaml` shape. Port of the nested structure `load_costs`
/// walks (`pricing`, `model_map`, `defaults`, `overlap.{pre_s,post_s}`,
/// `polling.{interval_s,timeout_s}`, `cost_guard`). Kept as a wire type so
/// `CostsConfig` itself stays flat (matching the Python dataclass), exactly as
/// `load_costs` flattens the nested YAML on load.
private struct CostsWire: Decodable {
    struct Overlap: Decodable {
        let preS: Double
        let postS: Double
        enum CodingKeys: String, CodingKey {
            case preS = "pre_s"
            case postS = "post_s"
        }
    }
    struct Polling: Decodable {
        let intervalS: Int
        let timeoutS: Int
        enum CodingKeys: String, CodingKey {
            case intervalS = "interval_s"
            case timeoutS = "timeout_s"
        }
    }

    let pricing: [String: ModelPricing]
    let modelMap: [String: String]
    let defaults: [String: String]
    let overlap: Overlap
    let polling: Polling
    let costGuard: CostGuard?

    enum CodingKeys: String, CodingKey {
        case pricing
        case modelMap = "model_map"
        case defaults
        case overlap
        case polling
        case costGuard = "cost_guard"
    }
}

/// Port of `render/costs.py::load_costs`. Parses a `costs.yaml`-shaped document.
/// `cost_guard` is optional and defaults to `CostGuard()` when absent, matching
/// `data.get("cost_guard", {})`.
public func loadCosts(fromYAML yaml: String) throws -> CostsConfig {
    let wire = try YAMLCoding.decode(CostsWire.self, from: yaml)
    return CostsConfig(
        pricing: wire.pricing,
        modelMap: wire.modelMap,
        defaults: wire.defaults,
        overlapPreS: wire.overlap.preS,
        overlapPostS: wire.overlap.postS,
        pollingIntervalS: wire.polling.intervalS,
        pollingTimeoutS: wire.polling.timeoutS,
        costGuard: wire.costGuard ?? CostGuard()
    )
}

/// Port of `render/costs.py::load_costs`, file variant. Reads and parses a
/// `costs.yaml` override from disk.
public func loadCosts(from url: URL) throws -> CostsConfig {
    try loadCosts(fromYAML: String(contentsOf: url, encoding: .utf8))
}

extension CostsConfig {
    /// The packaged default cost config — the values the Python engine expects
    /// at `repo_root()/costs.yaml`, embedded here as a literal so the Swift
    /// engine is self-contained (the Python side keeps `costs.yaml` as a
    /// deployment-external file; it ships no default). Prices are the
    /// authoritative fal Seedance-2 numbers documented in `brief/schema.py`
    /// (Pro 1080p $0.682/s, Pro 720p $0.3024/s, Fast 720p $0.2419/s) and the
    /// Runway-legacy `seedance2` 0.10 EUR/s from `render/costs.py`; 1 USD ≈ 1
    /// EUR per the costs.yaml header convention. `defaults`/`model_map`/overlap/
    /// polling/cost_guard mirror the shapes the unit tests and dispatcher use.
    ///
    /// `loadCosts(from:)` loads an override to replace this at runtime.
    public static let bundledDefault = CostsConfig(
        pricing: [
            "seedance2": ModelPricing(
                eurPerSecond: 0.10, maxDurationS: 10.0, defaultRatio: "16:9"
            ),
            "fal:bytedance/seedance-2.0/pro": ModelPricing(
                eurPerSecond: 0.682, maxDurationS: 10.0, defaultRatio: "16:9",
                minDurationS: 5.0,
                eurPerSecondByResolution: ["720p": 0.3024, "1080p": 0.682]
            ),
            "fal:bytedance/seedance-2.0/fast": ModelPricing(
                eurPerSecond: 0.2419, maxDurationS: 10.0, defaultRatio: "16:9",
                minDurationS: 5.0,
                eurPerSecondByResolution: ["720p": 0.2419]
            ),
        ],
        modelMap: ["SEEDANCE_2_0": "seedance2"],
        defaults: [
            "preview": "fal:bytedance/seedance-2.0/fast",
            "final": "fal:bytedance/seedance-2.0/pro",
        ],
        overlapPreS: 1.5,
        overlapPostS: 1.5,
        pollingIntervalS: 5,
        pollingTimeoutS: 600,
        costGuard: CostGuard(confirmThresholdEur: 10.0, projectWideBudget: true)
    )

    /// The same values as `bundledDefault`, serialized as a `costs.yaml`-shaped
    /// document. Handed to the Python oracle (and any override-file test) so both
    /// sides price identically — the golden is generated from this exact YAML.
    public static let bundledDefaultYAML = """
        pricing:
          seedance2:
            eur_per_second: 0.10
            max_duration_s: 10.0
            default_ratio: "16:9"
          "fal:bytedance/seedance-2.0/pro":
            eur_per_second: 0.682
            max_duration_s: 10.0
            default_ratio: "16:9"
            min_duration_s: 5.0
            eur_per_second_by_resolution:
              720p: 0.3024
              1080p: 0.682
          "fal:bytedance/seedance-2.0/fast":
            eur_per_second: 0.2419
            max_duration_s: 10.0
            default_ratio: "16:9"
            min_duration_s: 5.0
            eur_per_second_by_resolution:
              720p: 0.2419
        model_map:
          SEEDANCE_2_0: seedance2
        defaults:
          preview: "fal:bytedance/seedance-2.0/fast"
          final: "fal:bytedance/seedance-2.0/pro"
        overlap:
          pre_s: 1.5
          post_s: 1.5
        polling:
          interval_s: 5
          timeout_s: 600
        cost_guard:
          confirm_threshold_eur: 10.0
          project_wide_budget: true
        """
}
