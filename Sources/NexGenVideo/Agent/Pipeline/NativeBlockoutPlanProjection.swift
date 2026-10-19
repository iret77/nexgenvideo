import BpyRuntimeProtocol
import Foundation
import NexGenEngine
import simd

struct NativeBlockoutPlanProjection: Sendable {
    let snapshot: BpySpatialSnapshot
    let state: SpatialClayState
    let locationID: String
    let geometry: SpatialEvaluatedGeometryV1
    let horizontalOrigin: Double
    let depthOrigin: Double
    let layout: SpatialLayoutV1
    let verticalOrigin: Double

    init(snapshot: BpySpatialSnapshot, snapshotData: Data, state: SpatialClayState, geometry: SpatialEvaluatedGeometryV1, locationID: String) throws {
        guard try JSONDecoder().decode(BpySpatialSnapshot.self, from: snapshotData) == snapshot,
              SpatialSceneStore.digest(snapshotData) == geometry.snapshotSHA256,
              snapshot.units == "meters", !state.frames.isEmpty, geometry.frames.map(\.frame) == state.frames.map(\.frame),
              geometry.stateSHA256 == SpatialSceneStore.digest(try SpatialSceneStore.encode(state)),
              geometry.sceneManifestSHA256 == state.sceneManifestSHA256,
              snapshot.metersPerUnit.isFinite, snapshot.metersPerUnit > 0 else { throw Self.invalid() }
        guard Set(snapshot.objects.map(\.id)).count == snapshot.objects.count,
              geometry.frames.allSatisfy({ Set($0.meshes.map(\.id)).count == $0.meshes.count }),
              state.frames.allSatisfy({ Set($0.objects.map(\.objectID)).count == $0.objects.count }),
              zip(state.frames, geometry.frames).allSatisfy({ pair in
                  let objects = Set(pair.0.objects.map(\.objectID))
                  return objects == Set(snapshot.objects.map(\.id)) && objects.contains(state.cameraID)
                    && pair.1.sceneFrame == pair.0.frame && pair.1.metersPerUnit == snapshot.metersPerUnit
                    && pair.1.meshes.allSatisfy { objects.contains($0.objectID) }
              }) else { throw Self.invalid() }
        for (native, evaluated) in zip(state.frames, geometry.frames) {
            guard let camera = native.objects.first(where: { $0.objectID == state.cameraID }),
                  try SpatialEvaluatedGeometryV1.sameMatrix(evaluated.cameraMatrix, camera.matrixWorld),
                  Set(evaluated.objects.map(\.objectID)) == Set(native.objects.map(\.objectID)),
                  evaluated.objects.count == native.objects.count else { throw Self.invalid() }
            let expected = Dictionary(uniqueKeysWithValues: native.objects.map { ($0.objectID, $0.matrixWorld) })
            for pose in evaluated.objects {
                guard let matrix = expected[pose.objectID], try SpatialEvaluatedGeometryV1.sameMatrix(pose.matrixWorld, matrix) else { throw Self.invalid() }
            }
        }
        self.snapshot = snapshot; self.state = state; self.locationID = locationID; self.geometry = geometry
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for frame in geometry.frames {
            for mesh in frame.meshes {
                for point in try Self.points(mesh: mesh, scale: snapshot.metersPerUnit) {
                    lo = simd_min(lo, point); hi = simd_max(hi, point)
                }
            }
            let matrix = try SpatialShotPoseTimeline.matrix(frame.cameraMatrix)
            let origin = SIMD3(matrix[3][0], matrix[3][1], matrix[3][2])
            let forward = SIMD3(-matrix[2][0], -matrix[2][1], -matrix[2][2])
            guard simd_length(forward).isFinite, simd_length(forward) > 0 else { throw Self.invalid() }
            for position in [origin, origin + simd_normalize(forward)] {
                let point = Self.coordinate(position, scale: snapshot.metersPerUnit)
                lo = simd_min(lo, point); hi = simd_max(hi, point)
            }
        }
        guard [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z].allSatisfy(\.isFinite),
              [(hi - lo).x, (hi - lo).y, (hi - lo).z].allSatisfy(\.isFinite) else { throw Self.invalid() }
        verticalOrigin = lo.y
        horizontalOrigin = lo.x / 2 + hi.x / 2
        depthOrigin = lo.z / 2 + hi.z / 2
        layout = .init(locationID: locationID, widthMeters: max(0.001, hi.x - lo.x),
            depthMeters: max(0.001, hi.z - lo.z), heightMeters: max(0.001, hi.y - lo.y), setupIDs: [state.cameraID])
    }

    func frame(_ index: Int) throws -> NativeBlockoutExporter.PlanFrame {
        guard state.frames.indices.contains(index) else { throw Self.invalid() }
        let evaluated = geometry.frames[index]
        let shapes = try evaluated.meshes.map { mesh in
            let points = try Self.points(mesh: mesh, scale: snapshot.metersPerUnit)
            guard let first = points.first else { throw Self.invalid() }
            let lo = points.reduce(first) { simd_min($0, $1) }, hi = points.reduce(first) { simd_max($0, $1) }
            let center = lo / 2 + hi / 2, size = hi - lo
            return BlockoutShapeV1(id: mesh.id, entityID: mesh.objectID, entityStateIDs: [], locationID: locationID,
                primitive: .box, center: .init(x: center.x - horizontalOrigin, y: center.y - verticalOrigin, z: center.z - depthOrigin),
                size: .init(x: size.x, y: size.y, z: size.z), headingDegrees: 0)
        }
        let matrix = try SpatialShotPoseTimeline.matrix(evaluated.cameraMatrix)
        let original = SIMD3<Double>(matrix[3][0], matrix[3][1], matrix[3][2])
        let forward = SIMD3<Double>(-matrix[2][0], -matrix[2][1], -matrix[2][2])
        guard simd_length(forward).isFinite, simd_length(forward) > 0 else { throw Self.invalid() }
        let position = Self.coordinate(original, scale: snapshot.metersPerUnit)
        let target = Self.coordinate(original + simd_normalize(forward), scale: snapshot.metersPerUnit)
        let pos = SpatialVector3V1(x: position.x - horizontalOrigin, y: position.y - verticalOrigin, z: position.z - depthOrigin)
        let look = SpatialVector3V1(x: target.x - horizontalOrigin, y: target.y - verticalOrigin, z: target.z - depthOrigin)
        return .init(cameras: [.init(id: state.cameraID, locationID: locationID, position: pos,
            path: [.init(timeSeconds: 0, position: pos, lookAt: look)])], layouts: [layout], shapes: shapes, metric: true)
    }

    private static func points(mesh: SpatialEvaluatedGeometryV1.Mesh, scale: Double) throws -> [SIMD3<Double>] {
        guard mesh.minimum.count == 3, mesh.maximum.count == 3,
              (mesh.minimum + mesh.maximum).allSatisfy(\.isFinite),
              zip(mesh.minimum, mesh.maximum).allSatisfy({ $0.0 <= $0.1 }) else { throw invalid() }
        return [mesh.minimum[0], mesh.maximum[0]].flatMap { x in
            [mesh.minimum[1], mesh.maximum[1]].flatMap { y in
                [mesh.minimum[2], mesh.maximum[2]].map { z in coordinate(SIMD3(x, y, z), scale: scale) }
            }
        }
    }
    private static func coordinate(_ value: SIMD3<Double>, scale: Double) -> SIMD3<Double> { SIMD3(value.x, value.z, -value.y) * scale }
    private static func invalid() -> GateBlocked { GateBlocked("The plan/elevation export needs verified mesh geometry and every evaluated object and camera pose.") }
}
