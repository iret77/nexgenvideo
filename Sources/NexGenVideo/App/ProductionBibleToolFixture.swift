import Foundation
import NexGenEngine

@MainActor
enum ProductionBibleToolFixture {
    static func arguments(_ bible: Bible) throws -> [String: Any] {
        var result = ["look": try ProductionPlanningAcceptanceFixture.object(bible.look)]
        for (name, values) in [("characters", try ProductionPlanningAcceptanceFixture.object(bible.characters)),
                               ("ensembles", try ProductionPlanningAcceptanceFixture.object(bible.ensembles)),
                               ("props", try ProductionPlanningAcceptanceFixture.object(bible.props)),
                               ("locations", try ProductionPlanningAcceptanceFixture.object(bible.locations))] {
            guard let entities = values as? [[String: Any]] else { throw GateBlocked("The Bible fixture cannot encode its actual entities.") }
            result[name] = try entities.map { original in
                var entity = original
                guard (entity.removeValue(forKey: "hard_recognition_trait") as? String ?? "").isEmpty else {
                    throw GateBlocked("This fixture cannot round-trip an unsupported hard recognition trait.")
                }
                for (field, key, value) in [("attributes", "key", "value"), ("sheets", "view", "path"), ("view_purpose", "view", "purpose")] {
                    if let pairs = entity[field] as? [String: String] {
                        entity[field] = pairs.keys.sorted().map { [key: $0, value: pairs[$0]!] }
                    }
                }
                return entity
            }
        }
        return result
    }
}
