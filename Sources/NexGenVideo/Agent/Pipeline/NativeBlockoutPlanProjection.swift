import BpyRuntimeProtocol
import Foundation
import NexGenEngine
import simd

struct NativeBlockoutPlanProjection: Sendable {
    let snapshot: BpySpatialSnapshot
    let state: SpatialClayState
    let locationID: String
    let layout: SpatialLayoutV1
    let verticalOrigin: Double

    init(snapshot: BpySpatialSnapshot, state: SpatialClayState, locationID: String) throws {
        guard !state.frames.isEmpty, !snapshot.meshes.isEmpty, snapshot.metersPerUnit.isFinite, snapshot.metersPerUnit > 0 else { throw Self.invalid() }
        guard Set(snapshot.meshes.map(\.id)).count == snapshot.meshes.count,
              state.frames.allSatisfy({ Set($0.objects.map(\.objectID)).count == $0.objects.count }) else { throw Self.invalid() }
        self.snapshot = snapshot; self.state = state; self.locationID = locationID
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for frame in state.frames {
            let poses = Dictionary(uniqueKeysWithValues: frame.objects.map { ($0.objectID, $0.matrixWorld) })
            for mesh in snapshot.meshes {
                for point in try Self.points(mesh: mesh, poses: poses, scale: snapshot.metersPerUnit) {
                    lo = simd_min(lo, point); hi = simd_max(hi, point)
                }
            }
            guard let camera = poses[state.cameraID] else { throw Self.invalid() }
            let matrix = try SpatialShotPoseTimeline.matrix(camera)
            let point = Self.coordinate(SIMD3(matrix[3][0], matrix[3][1], matrix[3][2]), scale: snapshot.metersPerUnit)
            lo = simd_min(lo, point); hi = simd_max(hi, point)
        }
        guard [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z].allSatisfy(\.isFinite) else { throw Self.invalid() }
        guard (hi - lo).x.isFinite, (hi - lo).y.isFinite, (hi - lo).z.isFinite,
              (2 * max(abs(lo.x), abs(hi.x))).isFinite, (2 * max(abs(lo.z), abs(hi.z))).isFinite else { throw Self.invalid() }
        verticalOrigin = lo.y
        layout = .init(locationID: locationID, widthMeters: max(0.001, 2 * max(abs(lo.x), abs(hi.x))),
            depthMeters: max(0.001, 2 * max(abs(lo.z), abs(hi.z))), heightMeters: max(0.001, hi.y - lo.y), setupIDs: [state.cameraID])
    }

    func frame(_ index: Int) throws -> NativeBlockoutExporter.PlanFrame {
        guard state.frames.indices.contains(index) else { throw Self.invalid() }
        let stateFrame = state.frames[index]
        let poses = Dictionary(uniqueKeysWithValues: stateFrame.objects.map { ($0.objectID, $0.matrixWorld) })
        let shapes = try snapshot.meshes.map { mesh in
            let points = try Self.points(mesh: mesh, poses: poses, scale: snapshot.metersPerUnit)
            guard let first = points.first else { throw Self.invalid() }
            let lo = points.reduce(first) { simd_min($0, $1) }, hi = points.reduce(first) { simd_max($0, $1) }
            let center = (lo + hi) / 2, size = hi - lo
            return BlockoutShapeV1(id: mesh.id, entityID: mesh.objectID, entityStateIDs: [], locationID: locationID,
                primitive: .box, center: .init(x: center.x, y: center.y - verticalOrigin, z: center.z),
                size: .init(x: size.x, y: size.y, z: size.z), headingDegrees: 0)
        }
        guard let camera = poses[state.cameraID] else { throw Self.invalid() }
        let matrix = try SpatialShotPoseTimeline.matrix(camera)
        let original = SIMD3<Double>(matrix[3][0], matrix[3][1], matrix[3][2])
        let forward = SIMD3<Double>(-matrix[2][0], -matrix[2][1], -matrix[2][2])
        guard simd_length(forward).isFinite, simd_length(forward) > 0 else { throw Self.invalid() }
        let position = Self.coordinate(original, scale: snapshot.metersPerUnit)
        let target = Self.coordinate(original + simd_normalize(forward), scale: snapshot.metersPerUnit)
        let pos = SpatialVector3V1(x: position.x, y: position.y - verticalOrigin, z: position.z)
        let look = SpatialVector3V1(x: target.x, y: target.y - verticalOrigin, z: target.z)
        return .init(cameras: [.init(id: state.cameraID, locationID: locationID, position: pos,
            path: [.init(timeSeconds: 0, position: pos, lookAt: look)])], layouts: [layout], shapes: shapes)
    }

    private static func points(mesh: BpySpatialMesh, poses: [String: [Double]], scale: Double) throws -> [SIMD3<Double>] {
        guard let rows = poses[mesh.objectID], !mesh.positions.isEmpty else { throw invalid() }
        let matrix = try SpatialShotPoseTimeline.matrix(rows)
        return try mesh.positions.map { values in
            guard values.count == 3, values.allSatisfy(\.isFinite) else { throw invalid() }
            let point = matrix * SIMD4<Double>(values[0], values[1], values[2], 1)
            guard [point.x, point.y, point.z, point.w].allSatisfy(\.isFinite), abs(point.w - 1) < 0.000001 else { throw invalid() }
            return coordinate(SIMD3(point.x, point.y, point.z), scale: scale)
        }
    }
    private static func coordinate(_ value: SIMD3<Double>, scale: Double) -> SIMD3<Double> { SIMD3(value.x, value.z, -value.y) * scale }
    private static func invalid() -> GateBlocked { GateBlocked("The plan/elevation export needs verified mesh geometry and every evaluated object and camera pose.") }
}
