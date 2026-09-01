import Testing
@testable import NexGenEngine

@Suite("AssetGraph content addressing")
struct AssetGraphContentAddressTests {
    @Test("asset and graph identities cover provenance and allowed uses")
    func exactContentIdentity() throws {
        let asset = try AssetGraphContentAddressV1.reidentified(node(
            id: "pending",
            allowedUseIDs: ["look.identity"]
        ))
        let graph = AssetGraphV1(
            id: try AssetGraphContentAddressV1.graphID(
                projectID: "project",
                assets: [asset]
            ),
            projectID: "project",
            assets: [asset]
        )
        try AssetGraphValidatorV1.validate(graph)

        let changed = node(
            id: asset.id,
            allowedUseIDs: ["look.identity", "look.palette"]
        )
        let staleGraph = AssetGraphV1(
            id: graph.id,
            projectID: graph.projectID,
            assets: [changed]
        )
        #expect(throws: AssetGraphValidationError.invalidHash(asset.id)) {
            try AssetGraphValidatorV1.validate(staleGraph)
        }
    }

    private func node(id: String, allowedUseIDs: [String]) -> AssetGraphNodeV1 {
        AssetGraphNodeV1(
            id: id,
            version: 1,
            path: "media/reference.png",
            sha256: String(repeating: "a", count: 64),
            modality: .image,
            approval: .approved,
            provenance: AssetProvenanceV1(
                kindID: "fixture.import",
                recordedAt: "2026-08-31T00:00:00Z"
            ),
            allowedUseIDs: allowedUseIDs
        )
    }
}
