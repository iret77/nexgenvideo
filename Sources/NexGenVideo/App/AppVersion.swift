import Foundation

/// Bundle version, nil in bare `swift run` builds without an Info.plist.
enum AppVersion {
    static let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
}
