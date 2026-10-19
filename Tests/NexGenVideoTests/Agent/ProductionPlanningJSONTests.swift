import Foundation
import Testing
@testable import NexGenVideo

@Suite("Production planning arguments reject invalid JSON before serialization")
@MainActor
struct ProductionPlanningJSONTests {
    @Test func malformedContainersAndNonJSONValuesThrowRatherThanEnteringFoundationWrite() throws {
        let invalid: [Any?] = [nil, NSNull(), "scene", 1, true, [Date()], [Double.infinity], ["value": Double.nan]]
        for field in ["scenes", "proposal", "shots", "findings"] {
            for value in invalid {
                #expect(throws: (any Error).self) {
                    try ToolExecutor.decodePlanningArgument([String].self, value: value, field: field)
                }
            }
        }
        #expect(try ToolExecutor.decodePlanningArgument([String].self, value: ["scene"], field: "scenes") == ["scene"])
        #expect(try ToolExecutor.decodePlanningArgument([String: String].self,
            value: ["summary": "actual"], field: "proposal") == ["summary": "actual"])
        #expect(throws: (any Error).self) {
            try ToolExecutor.decodePlanningArgument([String].self, value: ["summary": "actual"], field: "scenes")
        }
    }
}
