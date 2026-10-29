import Foundation
import NexGenEngine

enum ProductionSpatialReferencePurposeAcceptance {
    static func verify(location: Location, viewID: String, bible: Bible, dataRoot: URL) throws -> [String: Bool] {
        guard let image = location.sheets[viewID] else { throw GateBlocked("The actual native Bible image is missing.") }
        let digest = try FileDigest.sha256(of: ProjectLocalFile.resolve(image, dataRoot: dataRoot))
        let purpose = CoreReferenceSemanticJobIDV1.referenceAnchor
        try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: dataRoot)
        try PipelineProductionAssetEvidence.requireReferencePurpose(path: image, sha256: digest,
            semanticJobID: purpose, dataRoot: dataRoot, geometry: true)
        var appearanceRejected = false
        do { try PipelineProductionAssetEvidence.requireReferencePurpose(path: image, sha256: digest,
            semanticJobID: purpose, dataRoot: dataRoot, geometry: false) }
        catch { appearanceRejected = true }
        guard appearanceRejected else { throw GateBlocked("The actual native Clay image was accepted as appearance.") }
        var alias = bible
        guard let index = alias.locations.firstIndex(where: { $0.id == location.id }) else { throw GateBlocked("The native location disappeared.") }
        alias.locations[index].sheets["invalid_alias"] = image
        alias.locations[index].viewPurpose["invalid_alias"] = location.viewPurpose[viewID]
        var aliasRejected = false
        do { try PipelineProductionAssetEvidence.requireBible(alias, dataRoot: dataRoot) }
        catch { aliasRejected = true }
        guard aliasRejected else { throw GateBlocked("A second Bible view bypassed its exact native view binding.") }

        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Native spatial reference purpose \(UUID().uuidString)")
        try FileManager.default.copyItem(at: dataRoot, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let copy = "native-appearance-copy.png"
        try FileManager.default.copyItem(at: ProjectLocalFile.resolve(image, dataRoot: temporary), to: temporary.appendingPathComponent(copy))
        guard try FileDigest.sha256(of: temporary.appendingPathComponent(copy)) == digest else { throw GateBlocked("The copied-image negative control changed its bytes.") }
        var copiedAppearanceRejected = false
        do { try PipelineProductionAssetEvidence.requireReferencePurpose(path: copy, sha256: digest,
            semanticJobID: purpose, dataRoot: temporary, geometry: false) }
        catch { copiedAppearanceRejected = true }
        guard copiedAppearanceRejected else { throw GateBlocked("Copying identical Clay bytes bypassed the appearance restriction.") }
        try PipelineProductionAssetEvidence.requireReferencePurpose(path: copy, sha256: digest,
            semanticJobID: purpose, dataRoot: temporary, geometry: true)
        return ["nativeGeometryAccepted": true, "nativeAppearanceRejected": true,
            "copiedAppearanceRejected": true, "copiedGeometryAccepted": true, "duplicateViewAliasRejected": true]
    }
}
