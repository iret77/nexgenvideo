import Foundation

/// Costs a provider reports for one finished job, in the provider's own unit. The field shapes come
/// from provider documentation and stay unverified until a live call confirms them; anything absent
/// or malformed reads as unknown, never as zero.
enum ProviderReportedCost {
    /// Runway `GET /v1/tasks/{id}` on a terminal task: `cost.credits`.
    static func runway(terminalTask json: [String: Any]?) -> GenerationProviderCost? {
        guard let cost = json?["cost"] as? [String: Any],
              let credits = number(cost["credits"]) else { return nil }
        return GenerationProviderCost(
            amount: credits,
            unit: "credits",
            source: "Runway GET /v1/tasks/{id} cost.credits"
        )
    }

    /// Marble `GET /marble/v1/operations/{id}` after success: `cost.total_credits` plus `line_items`.
    static func marble(operation data: Data) -> GenerationProviderCost? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cost = json["cost"] as? [String: Any],
              let total = number(cost["total_credits"]) else { return nil }
        let items = (cost["line_items"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            guard let name = item["name"] as? String, let credits = number(item["credits"]) else { return nil }
            return "\(name) \(format(credits))"
        }
        return GenerationProviderCost(
            amount: total,
            unit: "credits",
            source: "Marble GET /marble/v1/operations/{id} cost.total_credits"
                + (items.isEmpty ? "" : " (" + items.joined(separator: ", ") + ")")
        )
    }

    /// ElevenLabs `character-cost` response header on a generation.
    static func elevenLabs(characterCost header: String?) -> GenerationProviderCost? {
        guard let header,
              let value = Double(header.trimmingCharacters(in: .whitespaces)),
              value.isFinite, value >= 0 else { return nil }
        return GenerationProviderCost(
            amount: value,
            unit: "characters",
            source: "ElevenLabs character-cost response header"
        )
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let amount = number.doubleValue
        return amount.isFinite && amount >= 0 ? amount : nil
    }

    private static func format(_ amount: Double) -> String {
        amount.rounded() == amount && abs(amount) < 1e15 ? String(Int(amount)) : String(amount)
    }
}
