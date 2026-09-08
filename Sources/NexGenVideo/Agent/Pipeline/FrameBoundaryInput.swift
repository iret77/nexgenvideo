import Foundation
import NexGenEngine

struct FrameBoundaryInput: Codable, Sendable, Equatable {
    let characterCount: Int
    let characterPositions: String
    let gaze: String
    let visibleZones: [String]
    let framing: String?
    let cameraAngle: String?
    let cameraHeight: String?

    func validate() throws {
        guard characterCount >= 0,
              characterCount == 0 || (!characterPositions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !gaze.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              Set(visibleZones).count == visibleZones.count,
              visibleZones.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              [framing, cameraAngle, cameraHeight].compactMap({ $0 }).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ToolError("A frame boundary needs a nonnegative character count, explicit positions/gaze, and valid camera fields.")
        }
    }
}
