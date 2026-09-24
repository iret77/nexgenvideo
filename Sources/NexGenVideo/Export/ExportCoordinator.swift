import Foundation

extension Notification.Name {
    static let exportActivityChanged = Notification.Name("exportActivityChanged")
}

@MainActor
enum ExportCoordinator {
    private static var exportActive = false
    private static var activeProjectKey: String?
    private struct WaitingExport { let projectKey: String? }
    private static var waitingProjectKeys: [UUID: WaitingExport] = [:]

    struct ProjectStatus {
        let running: Bool
        let waiting: Int
        let otherProjectRunning: Bool
    }

    static var isExportActive: Bool { exportActive }

    static func status(for projectKey: String?) -> ProjectStatus {
        ProjectStatus(
            running: exportActive && activeProjectKey == projectKey,
            waiting: waitingProjectKeys.values.filter { $0.projectKey == projectKey }.count,
            otherProjectRunning: exportActive && activeProjectKey != projectKey
        )
    }

    static func beginExportIfIdle(projectKey: String? = nil) -> Bool {
        guard !exportActive else { return false }
        exportActive = true
        activeProjectKey = projectKey
        NotificationCenter.default.post(name: .exportActivityChanged, object: nil)
        return true
    }

    static func acquireExport(projectKey: String? = nil) async -> Bool {
        let ticket = UUID()
        waitingProjectKeys[ticket] = WaitingExport(projectKey: projectKey)
        NotificationCenter.default.post(name: .exportActivityChanged, object: nil)
        defer {
            waitingProjectKeys.removeValue(forKey: ticket)
            NotificationCenter.default.post(name: .exportActivityChanged, object: nil)
        }
        while exportActive {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        guard !Task.isCancelled else { return false }
        exportActive = true
        activeProjectKey = projectKey
        NotificationCenter.default.post(name: .exportActivityChanged, object: nil)
        return true
    }

    static func endExport() {
        exportActive = false
        activeProjectKey = nil
        NotificationCenter.default.post(name: .exportActivityChanged, object: nil)
    }

    static func waitWhileExportActive() async throws {
        while exportActive {
            try await Task.sleep(for: .seconds(2))
        }
    }
}
