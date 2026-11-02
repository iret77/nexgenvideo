import Foundation

@MainActor
enum AppResourceSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_APP_RESOURCES"] == "1" else { return }
        var section = "production"
        do {
            let root = Bundle.main.bundleURL.resolvingSymlinksInPath()
            guard root.pathExtension == "app" else { throw Failure.invalidApplication }
            let contract = try CoreProductionPhaseContract.resolve()
            guard contract.resourceRoot.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw Failure.externalResource
            }
            section = "model-capabilities"
            let corpus = try BundledModelCapabilityCorpus.load()
            guard !corpus.inventory.isEmpty else { throw Failure.emptyCorpus }
            section = "fcpxml"
            for version in FCPXMLVersion.allCases {
                let xml = Data("<fcpxml version=\"\(version.rawValue)\"><resources/></fcpxml>".utf8)
                _ = try FCPXMLSchemaValidator.validate(xml, version: version)
            }
            FileHandle.standardOutput.write(Data("SELFTEST_APP_RESOURCES_OK production model-capabilities fcpxml\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("SELFTEST_APP_RESOURCES_FAIL \(section)\n".utf8))
            exit(1)
        }
    }

    private enum Failure: Error {
        case invalidApplication
        case externalResource
        case emptyCorpus
    }
}
