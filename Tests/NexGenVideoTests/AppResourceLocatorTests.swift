import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Packaged application resources", .serialized)
struct AppResourceLocatorTests {
    @Test func packagedResourcesUseTheApplicationLayout() throws {
        let fixture = try makeBundle(executable: "NexGenVideo", files: ["ProductionWorkflow/brief.md": "packaged instructions"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var fallbackCalls = 0
        let root = try #require(AppResourceLocator.url(forResource: "ProductionWorkflow", bundle: fixture.bundle) {
            fallbackCalls += 1
            return .main
        })
        #expect(try String(contentsOf: root.appendingPathComponent("brief.md"), encoding: .utf8) == "packaged instructions")
        #expect(fallbackCalls == 0)
    }

    @Test func missingPackagedResourcesNeverUseADevelopmentBundle() throws {
        let fixture = try makeBundle(executable: "NexGenVideo", files: [:])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var fallbackCalls = 0
        let url = AppResourceLocator.url(forResource: "ProductionWorkflow", bundle: fixture.bundle) {
            fallbackCalls += 1
            return .main
        }
        #expect(url == nil)
        #expect(fallbackCalls == 0)
    }

    @Test func developmentHostsKeepTheirSwiftPMResources() throws {
        let host = try makeBundle(executable: "TestHost", files: [:])
        let resources = try makeBundle(executable: "ResourceFixture", files: ["Schemas/profile.dtd": "schema fixture"])
        defer {
            try? FileManager.default.removeItem(at: host.root)
            try? FileManager.default.removeItem(at: resources.root)
        }
        var fallbackCalls = 0
        let url = try #require(AppResourceLocator.url(
            forResource: "profile", withExtension: "dtd", subdirectory: "Schemas", bundle: host.bundle
        ) {
            fallbackCalls += 1
            return resources.bundle
        })
        #expect(try String(contentsOf: url, encoding: .utf8) == "schema fixture")
        #expect(fallbackCalls == 1)
    }

    @Test func productionConsumersReadTheirActualDeclaredResources() throws {
        let contract = try CoreProductionPhaseContract.resolve()
        #expect(contract.phases.map(\.declaration.id) == ProductionWorkflowV2.corePhases)
        let corpus = try BundledModelCapabilityCorpus.load()
        #expect(!corpus.inventory.isEmpty)
        for version in FCPXMLVersion.allCases {
            let xml = Data("<fcpxml version=\"\(version.rawValue)\"><resources/></fcpxml>".utf8)
            let report = try FCPXMLSchemaValidator.validate(xml, version: version)
            #expect(report.version == version)
            #expect(report.assetCount == 0)
            #expect(report.storyElementCount == 0)
        }
    }

    private func makeBundle(executable: String, files: [String: String]) throws -> (bundle: Bundle, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-resource-\(UUID().uuidString).app")
        let contents = root.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "tests.resource.\(UUID().uuidString)", "CFBundlePackageType": "APPL",
                    "CFBundleExecutable": executable, "CFBundleName": "ResourceFixture", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: contents.appendingPathComponent("MacOS/\(executable)"))
        for (path, text) in files {
            let url = resources.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return (try #require(Bundle(url: root)), root)
    }
}
