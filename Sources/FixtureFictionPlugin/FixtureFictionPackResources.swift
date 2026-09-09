import Foundation

enum FixtureFictionPackResources {
    private final class BundleFinder {}

    private static let rootName = "FixtureFictionPack"
    private static let nestedBundleName = "NexGenVideo_FixtureFictionPlugin.bundle"

    static func resourceRootURL() -> URL? {
        let fileManager = FileManager.default
        func containsRoot(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.appendingPathComponent(rootName).path)
        }
        func search(_ containers: [URL]) -> URL? {
            for container in containers {
                if containsRoot(container) { return container.appendingPathComponent(rootName) }
                let nested = container.appendingPathComponent(nestedBundleName)
                for candidate in [nested, nested.appendingPathComponent("Contents/Resources")] {
                    if containsRoot(candidate) {
                        return candidate.appendingPathComponent(rootName)
                    }
                }
                if let resources = Bundle(url: nested)?.resourceURL, containsRoot(resources) {
                    return resources.appendingPathComponent(rootName)
                }
            }
            return nil
        }

        let bundle = Bundle(for: BundleFinder.self)
        let primary = [
            bundle.resourceURL,
            bundle.bundleURL,
            bundle.bundleURL.deletingLastPathComponent(),
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
        ].compactMap { $0 }
        if let found = search(primary) { return found }
        var fallback = Bundle.allBundles.compactMap(\.resourceURL)
        fallback += Bundle.allBundles.map(\.bundleURL)
        fallback += Bundle.allFrameworks.compactMap(\.resourceURL)
        return search(fallback)
    }

    static func phaseDoc(_ phase: String) throws -> String {
        guard let root = resourceRootURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(
            contentsOf: root.appendingPathComponent("phases/\(phase.replacingOccurrences(of: "_", with: "-")).md"),
            encoding: .utf8
        )
    }
}
