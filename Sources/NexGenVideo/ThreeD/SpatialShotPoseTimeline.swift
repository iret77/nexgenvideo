import Foundation
import simd

struct SpatialShotPoseTimeline: Sendable {
    let frameCount: Int
    var keyframes: [Int: SpatialClayStateFrame]

    init(frameCount: Int, keyframes: [Int: SpatialClayStateFrame]) {
        self.frameCount = frameCount; self.keyframes = keyframes
    }

    init(state: SpatialClayState, authoringFrames: [Int]?) throws {
        let indices = authoringFrames ?? state.frames.map(\.frame)
        guard !state.frames.isEmpty, state.frames.map(\.frame) == Array(state.frames.indices),
              indices == indices.sorted(), Set(indices).count == indices.count,
              indices.first == 0, indices.last == state.frames.count - 1,
              indices.allSatisfy({ state.frames.indices.contains($0) }) else { throw Self.invalid() }
        self.init(frameCount: state.frames.count, keyframes: Dictionary(uniqueKeysWithValues: indices.map { ($0, state.frames[$0]) }))
        guard try resolve(sceneManifestSHA256: state.sceneManifestSHA256, cameraID: state.cameraID) == state else { throw Self.invalid() }
    }

    func resolved(at frame: Int) throws -> SpatialClayStateFrame {
        guard (0..<frameCount).contains(frame), let first = keyframes.keys.filter({ $0 <= frame }).max(),
              let last = keyframes.keys.filter({ $0 >= frame }).min(),
              let a = keyframes[first], let b = keyframes[last] else { throw invalid() }
        guard a.frame == first, b.frame == last,
              !a.objects.isEmpty, Set(a.objects.map(\.objectID)).count == a.objects.count,
              Set(b.objects.map(\.objectID)).count == b.objects.count,
              Set(a.objects.map(\.objectID)) == Set(b.objects.map(\.objectID)),
              a.cameraVerticalFieldOfView.isFinite, b.cameraVerticalFieldOfView.isFinite,
              a.cameraVerticalFieldOfView > 0, b.cameraVerticalFieldOfView > 0,
              a.cameraVerticalFieldOfView < .pi, b.cameraVerticalFieldOfView < .pi else { throw invalid() }
        if first == last { return a }
        let amount = Double(frame - first) / Double(last - first)
        let right = Dictionary(uniqueKeysWithValues: b.objects.map { ($0.objectID, $0) })
        let objects = try a.objects.map { left in
            guard let other = right[left.objectID] else { throw invalid() }
            return SpatialClayObjectPose(objectID: left.objectID,
                matrixWorld: try Self.interpolate(left.matrixWorld, other.matrixWorld, amount: amount))
        }
        return .init(frame: frame, objects: objects,
            cameraVerticalFieldOfView: a.cameraVerticalFieldOfView + amount * (b.cameraVerticalFieldOfView - a.cameraVerticalFieldOfView))
    }

    func resolve(sceneManifestSHA256: String, cameraID: String) throws -> SpatialClayState {
        .init(sceneManifestSHA256: sceneManifestSHA256, cameraID: cameraID,
              frames: try (0..<frameCount).map { try resolved(at: $0) })
    }

    static func matrix(_ rows: [Double]) throws -> simd_double4x4 {
        guard rows.count == 16, rows.allSatisfy(\.isFinite) else { throw invalid() }
        return simd_double4x4(columns: (
            [rows[0], rows[4], rows[8], rows[12]], [rows[1], rows[5], rows[9], rows[13]],
            [rows[2], rows[6], rows[10], rows[14]], [rows[3], rows[7], rows[11], rows[15]]))
    }

    static func rows(_ matrix: simd_double4x4) -> [Double] { (0..<4).flatMap { row in (0..<4).map { matrix[$0][row] } } }

    static func transform(position: SIMD3<Double>, rotationDegrees: SIMD3<Double>, scale: SIMD3<Double>) throws -> [Double] {
        guard [position.x, position.y, position.z, rotationDegrees.x, rotationDegrees.y, rotationDegrees.z,
               scale.x, scale.y, scale.z].allSatisfy(\.isFinite), min(scale.x, scale.y, scale.z) > 0 else { throw invalid() }
        let angles = rotationDegrees * (.pi / 180)
        let rotation = simd_quatd(angle: angles.z, axis: [0, 0, 1]) * simd_quatd(angle: angles.y, axis: [0, 1, 0])
            * simd_quatd(angle: angles.x, axis: [1, 0, 0])
        var result = simd_double4x4(rotation)
        result.columns.0 *= scale.x; result.columns.1 *= scale.y; result.columns.2 *= scale.z
        result.columns.3 = [position.x, position.y, position.z, 1]
        return rows(result)
    }

    static func components(_ rows: [Double]) throws -> (position: SIMD3<Double>, rotation: SIMD3<Double>, scale: SIMD3<Double>) {
        let value = try decomposed(rows)
        let matrix = simd_double3x3(value.rotation)
        let pitch = asin(max(-1, min(1, -matrix[0][2])))
        let singular = abs(cos(pitch)) < 0.000001
        let roll = singular ? atan2(-matrix[2][1], matrix[1][1]) : atan2(matrix[1][2], matrix[2][2])
        let yaw = singular ? 0 : atan2(matrix[0][1], matrix[0][0])
        let angles = SIMD3<Double>(roll, pitch, yaw) * (180 / .pi)
        return (value.position, angles, value.scale)
    }

    private static func interpolate(_ a: [Double], _ b: [Double], amount: Double) throws -> [Double] {
        if a == b { return a }
        let left = try decomposed(a), right = try decomposed(b)
        var matrix = simd_double4x4(simd_slerp(left.rotation, right.rotation, amount))
        let scale = left.scale + (right.scale - left.scale) * amount
        let position = left.position + (right.position - left.position) * amount
        matrix.columns.0 *= scale.x; matrix.columns.1 *= scale.y; matrix.columns.2 *= scale.z
        matrix.columns.3 = [position.x, position.y, position.z, 1]
        return rows(matrix)
    }

    private static func decomposed(_ rows: [Double]) throws -> (position: SIMD3<Double>, rotation: simd_quatd, scale: SIMD3<Double>) {
        let matrix = try matrix(rows)
        guard abs(matrix[0][3]) < 0.000001, abs(matrix[1][3]) < 0.000001,
              abs(matrix[2][3]) < 0.000001, abs(matrix[3][3] - 1) < 0.000001 else { throw invalid() }
        let x = SIMD3<Double>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
        let y = SIMD3<Double>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
        let z = SIMD3<Double>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        let scale = SIMD3<Double>(simd_length(x), simd_length(y), simd_length(z))
        guard min(scale.x, scale.y, scale.z) > 0.000001 else { throw invalid() }
        let basis = simd_double3x3(columns: (x / scale.x, y / scale.y, z / scale.z))
        guard abs(simd_dot(basis[0], basis[1])) < 0.000001, abs(simd_dot(basis[0], basis[2])) < 0.000001,
              abs(simd_dot(basis[1], basis[2])) < 0.000001, abs(simd_determinant(basis) - 1) < 0.000001 else {
            throw SpatialSceneError.invalid("This object contains shear or a reflected scale. Adjust its original geometry in Production Design before interpolating its pose.")
        }
        return ([matrix[3][0], matrix[3][1], matrix[3][2]], simd_quatd(basis), scale)
    }

    private func invalid() -> SpatialSceneError { Self.invalid() }
    private static func invalid() -> SpatialSceneError { .invalid("The shot pose or its keyframes are incomplete. Review the selected object and frame.") }
}

struct SpatialShotPoseEdit: Sendable {
    private let original: SpatialClayStateFrame?
    private let objectID: String?
    private let baseline: (position: SIMD3<Double>, rotation: SIMD3<Double>, scale: SIMD3<Double>)?
    let failure: String?
    var position: SIMD3<Double>
    var rotation: SIMD3<Double>
    var scale: SIMD3<Double>
    var fieldOfView: Double

    init(pose: SpatialClayStateFrame? = nil, objectID: String? = nil) {
        original = pose; self.objectID = objectID
        var components: (position: SIMD3<Double>, rotation: SIMD3<Double>, scale: SIMD3<Double>)?
        var errorText: String?
        if let object = pose?.objects.first(where: { $0.objectID == objectID }) {
            do { components = try SpatialShotPoseTimeline.components(object.matrixWorld) }
            catch { errorText = error.localizedDescription }
        }
        baseline = components; failure = errorText
        position = components?.position ?? .zero
        rotation = components?.rotation ?? .zero
        scale = components?.scale ?? .init(repeating: 1)
        fieldOfView = (pose?.cameraVerticalFieldOfView ?? (.pi / 3)) * 180 / .pi
    }

    var transformEditable: Bool { baseline != nil }
    var transformChanged: Bool {
        guard let baseline else { return false }
        return position != baseline.position || rotation != baseline.rotation || scale != baseline.scale
    }
    var hasChanges: Bool {
        guard let original else { return false }
        return transformChanged || fieldOfView != original.cameraVerticalFieldOfView * 180 / .pi
    }
    var canSetKeyframe: Bool { original != nil && (transformEditable || hasChanges) }

    func applying() throws -> SpatialClayStateFrame {
        guard let original, fieldOfView.isFinite, fieldOfView > 0, fieldOfView < 180 else {
            throw SpatialSceneError.invalid("Enter a camera field of view between 0 and 180 degrees.")
        }
        let matrix = transformChanged ? try SpatialShotPoseTimeline.transform(position: position, rotationDegrees: rotation, scale: scale) : nil
        return .init(frame: original.frame, objects: original.objects.map {
            guard let matrix, $0.objectID == objectID else { return $0 }
            return .init(objectID: $0.objectID, matrixWorld: matrix)
        }, cameraVerticalFieldOfView: fieldOfView == original.cameraVerticalFieldOfView * 180 / .pi
            ? original.cameraVerticalFieldOfView : fieldOfView * .pi / 180)
    }
}
