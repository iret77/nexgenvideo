import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("FilmFlow portable snapshots through the actual MCP decoder", .serialized)
struct FilmFlowSnapshotTests {
    @Test func resourceAndAssetOriginsRejectCredentialsAndLocalAddresses() throws {
        #expect(FilmFlowHTTP.isResource(URL(string: "https://app.filmflow.pro/api/mcp")!))
        for address in ["https://app.filmflow.pro/api/mcp?token=x", "https://other.invalid/api/mcp", "https://app.filmflow.pro/api/mcp/", "http://app.filmflow.pro/api/mcp"] {
            #expect(!FilmFlowHTTP.isResource(URL(string: address)!))
        }
        for address in ["http://public.invalid/image.png", "https://user:secret@public.invalid/image.png", "https://localhost/image.png", "https://127.0.0.1/image.png", "https://[::1]/image.png", "https://public.invalid:8443/image.png", "https://public.invalid/image.png#token"] {
            #expect(throws: (any Error).self) { try FilmFlowHTTP.requireHTTPS(URL(string: address)!) }
        }
        try FilmFlowHTTP.requireHTTPS(URL(string: "https://public.invalid/image.png?signature=temporary")!)
    }

    @Test func capturesDecodedTextObservationsAndRedactedPortableBytesSeparately() async throws {
        let value = try await capture()
        defer { value.discard() }
        let actual = try FilmFlowSnapshot.verify(directory: value.directory, expectedSHA256: value.manifestSHA256)
        #expect(actual.responses.count == 4)
        #expect(actual.images.count == 1 && actual.images[0].pointers.count == 2)
        #expect(actual.missingImages.map(\.pointer) == ["list_entities#/1/referenceImageUrl"])
        for response in actual.responses {
            let original = try FilmFlowAcceptanceHTTP.response(response.tool)
            #expect(response.sourceObservationUTF8SHA256 == FileDigest.sha256(of: original))
            #expect(response.sourceObservationUTF8Count == original.count)
            let portable = try Data(contentsOf: value.directory.appendingPathComponent(response.portablePath))
            #expect(response.portableDTOSHA256 == FileDigest.sha256(of: portable))
            #expect(!String(decoding: portable, as: UTF8.self).contains("signature="))
            #expect(!String(decoding: portable, as: UTF8.self).contains("unknownSecretURL"))
        }
        let detail = try #require(actual.responses.first { $0.tool == "get_project" })
        #expect(detail.omissions.contains("/unknownSecretURL"))
        let material = try FilmFlowMaterial.load(directory: value.directory, snapshot: actual)
        let entities = material.items.filter { $0.kind == .entity }
        #expect(entities.count == 2 && entities[0].id != entities[1].id)
        #expect(entities[0].entity?.name == entities[1].entity?.name)
        #expect(FilmFlowAcceptanceHTTP.calls().filter { $0["tool"] == "get_project" }.count == 2)
    }

    @Test func noActiveScriptIsProjectAndEntityMaterialWithoutInventedText() async throws {
        let value = try await capture(.noActiveScript)
        defer { value.discard() }
        #expect(value.snapshot.noActiveScript)
        #expect(Set(value.snapshot.responses.map(\.tool)) == ["get_project", "list_entities"])
        let material = try FilmFlowMaterial.load(directory: value.directory, snapshot: value.snapshot)
        #expect(!material.items.contains { $0.kind == .scene || $0.kind == .shot })
        #expect(!FilmFlowAcceptanceHTTP.calls().contains { ["list_scenes", "get_shotlist"].contains($0["tool"] ?? "") })
    }

    @Test func cancellingActualSDKInitializationSettlesAndAllowsFreshConnection() async throws {
        FilmFlowAcceptanceHTTP.install(image: Data())
        FilmFlowAcceptanceHTTP.holdNextInitialize()
        let reader = FilmFlowAcceptanceHTTP.reader(connection: FilmFlowAcceptanceHTTP.connection())
        var finished = false
        let operation = Task {
            do { _ = try await reader.projects(); Issue.record("Cancelled initialization completed successfully.") }
            catch { #expect(error is CancellationError) }
            finished = true
        }
        defer { operation.cancel() }
        let clock = ContinuousClock()
        let started = clock.now
        while FilmFlowAcceptanceHTTP.heldReadCount() == 0, clock.now - started < .seconds(3) {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard FilmFlowAcceptanceHTTP.heldReadCount() == 1 else {
            operation.cancel(); await reader.close()
            Issue.record("The actual SDK Initialize request was not observed."); return
        }
        operation.cancel()
        let cancelled = clock.now
        while (!finished || FilmFlowAcceptanceHTTP.cancelledReadCount() != 1), clock.now - cancelled < .seconds(3) {
            try await Task.sleep(for: .milliseconds(5))
        }
        await reader.close()
        try #require(finished && FilmFlowAcceptanceHTTP.cancelledReadCount() == 1)
        let projects = try await reader.projects()
        #expect(projects.map(\.projectId) == [FilmFlowAcceptanceHTTP.projectID])
        await reader.close()
    }

    @Test func disappearingScriptReturnsTheActualToolErrorAndNeverACandidate() async throws {
        do { let value = try await capture(.scriptDisappears); value.discard(); Issue.record("Capture accepted a missing active Script.") }
        catch { #expect(error.localizedDescription.contains("no active script")) }
    }

    @Test func metadataChangeBetweenReadsRejectsTheCapture() async throws {
        await #expect(throws: (any Error).self) { _ = try await capture(.metadataChanges) }
    }

    @Test func aListedDigestDoesNotAuthorizeChangedDTOOrExtraRawFiles() async throws {
        let value = try await capture()
        defer { value.discard() }
        let file = value.directory.appendingPathComponent("dto/get_shotlist.json")
        let original = try Data(contentsOf: file)
        try Data("{}".utf8).write(to: file)
        #expect(throws: (any Error).self) { _ = try FilmFlowSnapshot.verify(directory: value.directory, expectedSHA256: value.manifestSHA256) }
        try original.write(to: file)
        let raw = value.directory.appendingPathComponent("wire-response.json")
        try Data("unlisted".utf8).write(to: raw)
        #expect(throws: (any Error).self) { _ = try FilmFlowSnapshot.verify(directory: value.directory, expectedSHA256: value.manifestSHA256) }
    }

    @Test func identicalOutsideImageViaSymlinkIsNotPortable() async throws {
        let value = try await capture()
        defer { value.discard() }
        let item = try #require(value.snapshot.images.first)
        let path = value.directory.appendingPathComponent(item.path)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.moveItem(at: path, to: outside)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        #expect(throws: (any Error).self) { _ = try FilmFlowSnapshot.verify(directory: value.directory, expectedSHA256: value.manifestSHA256) }
    }

    @Test func agentAssetCopyCannotReadOrWriteSnapshotsAndAdoptionHistory() throws {
        for source in [false, true] {
            for path in ["import/filmflow/a/dto/get_project.json", "pipeline/import/filmflow/a/images/x.png",
                         "import/filmflow-adoptions/a/accepted.json", "pipeline/import/filmflow-adoptions/a/x.json",
                         "import/FilmFlow/a/x.png", "import/../import/filmflow/a/x.png", "pipeline/./import/filmflow/a/x.png"] {
                #expect(throws: (any Error).self) { try ToolExecutor.requirePipelineAssetCopyPath(path, source: source) }
            }
        }
        try ToolExecutor.requirePipelineAssetCopyPath("import/ordinary.png", source: true)
    }

    static func prepared(_ mode: FilmFlowAcceptanceHTTP.Scenario = .normal) async throws -> FilmFlowSnapshot.Prepared {
        let image = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: image) }
        try FullflowAcceptanceFixture.writeReference(to: image)
        FilmFlowAcceptanceHTTP.install(image: try Data(contentsOf: image), scenario: mode)
        let reader = FilmFlowAcceptanceHTTP.reader(connection: FilmFlowAcceptanceHTTP.connection())
        do {
            let projects = try await reader.projects()
            let selected = try #require(projects.first)
            let value = try await reader.capture(project: selected)
            await reader.close()
            return value
        } catch { await reader.close(); throw error }
    }
    private func capture(_ mode: FilmFlowAcceptanceHTTP.Scenario = .normal) async throws -> FilmFlowSnapshot.Prepared {
        try await Self.prepared(mode)
    }
}
