import Foundation

enum AppResourceLocator {
    static func url(
        forResource name: String,
        withExtension resourceExtension: String? = nil,
        subdirectory: String? = nil,
        bundle: Bundle = .main,
        swiftPMBundle: () -> Bundle = { .module }
    ) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: resourceExtension, subdirectory: subdirectory) {
            return url
        }
        // The assembled app must not fall back to SwiftPM's build-directory bundle.
        if bundle.bundleURL.pathExtension == "app",
           bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "NexGenVideo" {
            return nil
        }
        return swiftPMBundle().url(forResource: name, withExtension: resourceExtension, subdirectory: subdirectory)
    }
}
