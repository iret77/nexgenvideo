import Foundation

public struct BpySpatialSnapshot: Codable, Sendable, Equatable {
    public let schema: String
    public let units: String
    public let metersPerUnit: Double
    public let frame: Int
    public let restFrame: Int
    public let framesPerSecond: Double
    public let timebaseNumerator: Int
    public let timebaseDenominator: Int
    public let objects: [BpySpatialObject]
    public let cameras: [BpySpatialCamera]
    public let meshes: [BpySpatialMesh]
    public let externalPaths: [String]
}

public struct BpySpatialObject: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let matrixWorld: [Double]
}

public struct BpySpatialCamera: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let matrixWorld: [Double]
    public let projection: [Double]
    public let verticalFieldOfView: Double
    public let near: Double
    public let far: Double
    public let width: Int
    public let height: Int
}

public struct BpySpatialMesh: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let objectID: String
    public let matrixWorld: [Double]
    public let positions: [[Double]]
    public let triangles: [UInt32]
}
