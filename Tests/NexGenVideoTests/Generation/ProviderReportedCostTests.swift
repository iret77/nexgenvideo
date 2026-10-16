import Foundation
import Testing

@testable import NexGenVideo

/// Fixtures follow the providers' documented response shapes (research for #643, 2026-10-16).
/// None of these fields has been confirmed by a live call yet.
@Suite("Provider-reported run costs")
struct ProviderReportedCostTests {
    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func runwayCreditsAreReadOnlyFromTheDocumentedCostObject() throws {
        let documented = try json(#"{"id":"t","status":"SUCCEEDED","output":["u"],"cost":{"credits":125}}"#)
        #expect(ProviderReportedCost.runway(terminalTask: documented)?.amount == 125)
        #expect(ProviderReportedCost.runway(terminalTask: documented)?.unit == "credits")
        for malformed in [
            #"{"status":"SUCCEEDED","output":["u"]}"#,
            #"{"status":"SUCCEEDED","cost":null}"#,
            #"{"status":"SUCCEEDED","cost":{"credits":"125"}}"#,
            #"{"status":"SUCCEEDED","cost":{"credits":true}}"#,
            #"{"status":"SUCCEEDED","cost":{"credits":-5}}"#,
            #"{"status":"RUNNING","estimatedCost":{"credits":125}}"#,
        ] {
            #expect(ProviderReportedCost.runway(terminalTask: try json(malformed)) == nil)
        }
        #expect(ProviderReportedCost.runway(terminalTask: nil) == nil)
    }

    @Test func marbleTotalCreditsKeepTheirLineItemsAsEvidence() {
        let finished = Data(#"""
        {"operation_id":"op_1","done":true,"error":null,"response":{"id":"world_1"},
         "cost":{"total_credits":1580,"line_items":[{"name":"world_generation","credits":1500},{"name":"pano_generation","credits":80}]}}
        """#.utf8)
        let cost = ProviderReportedCost.marble(operation: finished)
        #expect(cost?.amount == 1580)
        #expect(cost?.unit == "credits")
        #expect(cost?.source.contains("world_generation 1500") == true)
        #expect(cost?.source.contains("pano_generation 80") == true)

        let failed = Data(#"{"operation_id":"op_2","done":true,"error":{"message":"x"},"cost":null}"#.utf8)
        #expect(ProviderReportedCost.marble(operation: failed) == nil)
        #expect(ProviderReportedCost.marble(operation: Data(#"{"done":true}"#.utf8)) == nil)
        #expect(ProviderReportedCost.marble(operation: Data("not json".utf8)) == nil)
    }

    @Test func elevenLabsCharacterCostHeaderIsRecordedAsCharacters() {
        let cost = ProviderReportedCost.elevenLabs(characterCost: " 1234 ")
        #expect(cost?.amount == 1234)
        #expect(cost?.unit == "characters")
        #expect(ProviderReportedCost.elevenLabs(characterCost: nil) == nil)
        #expect(ProviderReportedCost.elevenLabs(characterCost: "unknown") == nil)
        #expect(ProviderReportedCost.elevenLabs(characterCost: "-3") == nil)
    }
}
