import Foundation

/// Runs the shared catalog/update state machine once at launch.
@MainActor
enum PluginAutoUpdate {
    static func run() async {
        await PluginUpdateCenter.shared.checkAndStageUpdates()
    }
}
