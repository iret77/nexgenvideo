import Foundation

public struct PhaseProgress: Sendable, Equatable {
    public let sourceFilename: String?
    public let stageID: String
    public let completedUnitCount: Int
    public let totalUnitCount: Int
    public let nextStageID: String?

    public init(
        sourceFilename: String? = nil,
        stageID: String,
        completedUnitCount: Int,
        totalUnitCount: Int,
        nextStageID: String? = nil
    ) {
        self.sourceFilename = sourceFilename
        self.stageID = stageID
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.nextStageID = nextStageID
    }
}
