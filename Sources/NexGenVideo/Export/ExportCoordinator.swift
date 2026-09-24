import Foundation

extension Notification.Name {
    static let exportActivityChanged = Notification.Name("exportActivityChanged")
}

@MainActor
enum ExportCoordinator {
    private static var exportActive = false

    static var isExportActive: Bool { exportActive }

    static func beginExportIfIdle() -> Bool {
        guard !exportActive else { return false }
        exportActive = true
        NotificationCenter.default.post(name: .exportActivityChanged, object: nil)
        return true
    }

    static func acquireExport() async {
        while exportActive {
            try? await Task.sleep(for: .milliseconds(50))
        }
        exportActive = true
        NotificationCenter.default.post(name: .exportActivityChanged, object: nil)
    }

    static func endExport() {
        exportActive = false
        NotificationCenter.default.post(name: .exportActivityChanged, object: nil)
    }

    static func waitWhileExportActive() async throws {
        while exportActive {
            try await Task.sleep(for: .seconds(2))
        }
    }
}
