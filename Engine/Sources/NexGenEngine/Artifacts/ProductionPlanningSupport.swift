import Foundation

public enum ProductionPlanningError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)
    case stale(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let field): "Invalid production planning field: \(field)."
        case .stale(let artifact): "Production planning evidence changed: \(artifact)."
        }
    }
}

public struct RationalTimebaseV1: Codable, Sendable, Equatable {
    public let ticksPerSecond: Int64
    public let fpsNumerator: Int64
    public let fpsDenominator: Int64

    public init(ticksPerSecond: Int64, fpsNumerator: Int64, fpsDenominator: Int64 = 1) {
        self.ticksPerSecond = ticksPerSecond
        self.fpsNumerator = fpsNumerator
        self.fpsDenominator = fpsDenominator
    }

    public func validate() throws {
        try PlanningValidation.require(ticksPerSecond > 0 && ticksPerSecond <= Int64(Int32.max), "timebase.ticksPerSecond")
        try PlanningValidation.require(fpsNumerator > 0 && fpsDenominator > 0, "timebase.fps")
        let product = ticksPerSecond.multipliedReportingOverflow(by: fpsDenominator)
        try PlanningValidation.require(!product.overflow && product.partialValue % fpsNumerator == 0, "timebase.frameTicks")
    }

    public func seconds(for ticks: Int64) -> Double {
        Double(ticks) / Double(ticksPerSecond)
    }

    public func representsSameTime(_ ticks: Int64, as otherTicks: Int64, timebase other: Self) -> Bool {
        guard ticksPerSecond > 0, other.ticksPerSecond > 0,
              ticksPerSecond <= Int64(Int32.max), other.ticksPerSecond <= Int64(Int32.max),
              ticks / ticksPerSecond == otherTicks / other.ticksPerSecond else { return false }
        return (ticks % ticksPerSecond) * other.ticksPerSecond == (otherTicks % other.ticksPerSecond) * ticksPerSecond
    }

    public var framesPerSecond: Double { Double(fpsNumerator) / Double(fpsDenominator) }
}

public struct SourceFootageRangeV1: Codable, Sendable, Equatable {
    public let source: CanonicalArtifactReferenceV1
    public let timebase: RationalTimebaseV1
    public let startTicks: Int64
    public let durationTicks: Int64

    public init(source: CanonicalArtifactReferenceV1, timebase: RationalTimebaseV1, startTicks: Int64, durationTicks: Int64) {
        self.source = source
        self.timebase = timebase
        self.startTicks = startTicks
        self.durationTicks = durationTicks
    }

    public func validate() throws {
        try PlanningValidation.reference(source)
        try timebase.validate()
        _ = try PlanningValidation.end(start: startTicks, duration: durationTicks)
    }
}

public struct PlanningArtifactHeaderV1: Codable, Sendable, Equatable {
    public enum Origin: String, Codable, Sendable {
        case agentProposal, agentRevision, userSupplied, userRevision, adopted
    }

    public let projectID: String
    public let revision: Int
    public let origin: Origin
    public let inputs: [CanonicalArtifactReferenceV1]

    public init(projectID: String, revision: Int, origin: Origin, inputs: [CanonicalArtifactReferenceV1]) {
        self.projectID = projectID
        self.revision = revision
        self.origin = origin
        self.inputs = inputs
    }

    public func validate() throws {
        try PlanningValidation.text(projectID, "header.projectID")
        try PlanningValidation.require(revision > 0, "header.revision")
        try PlanningValidation.unique(inputs.map(\.id), "header.inputs.id")
        try PlanningValidation.unique(inputs.map(\.path), "header.inputs.path")
        for input in inputs { try PlanningValidation.reference(input) }
    }

    public func requireCurrentInputs(dataRoot: URL) throws {
        try validate()
        for input in inputs {
            _ = try ProjectLocalFile.requireHash(input.sha256, at: input.path, dataRoot: dataRoot)
        }
    }
}

enum PlanningValidation {
    static func require(_ condition: Bool, _ field: String) throws {
        guard condition else { throw ProductionPlanningError.invalid(field) }
    }

    static func text(_ value: String, _ field: String) throws {
        try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, field)
    }

    static func identifier(_ value: String, _ field: String) throws {
        try require(!value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }, field)
    }

    static func shotID(_ value: String) throws {
        guard value.hasPrefix("shot-"), let uuid = UUID(uuidString: String(value.dropFirst(5))),
              value == "shot-" + uuid.uuidString.lowercased() else {
            throw ProductionPlanningError.invalid("plan_shot_id")
        }
    }

    static func unique(_ values: [String], _ field: String) throws {
        try require(Set(values).count == values.count, field)
        for value in values { try text(value, field) }
    }

    static func hash(_ value: String, _ field: String) throws {
        try require(value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }, field)
    }

    static func path(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        try require(!value.isEmpty && !value.hasPrefix("/") && !value.contains("\\")
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), "path")
    }

    static func reference(_ value: CanonicalArtifactReferenceV1) throws {
        try identifier(value.id, "reference.id")
        try text(value.role, "reference.role")
        try path(value.path)
        try hash(value.sha256, "reference.sha256")
    }

    static func end(start: Int64, duration: Int64) throws -> Int64 {
        try require(start >= 0 && duration > 0, "interval")
        let sum = start.addingReportingOverflow(duration)
        try require(!sum.overflow, "interval.overflow")
        return sum.partialValue
    }
}
