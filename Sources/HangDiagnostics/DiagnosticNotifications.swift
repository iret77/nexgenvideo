import Foundation

public enum DiagnosticNotifications {
    public static func acknowledge(_ requests: [String], defaults: UserDefaults = .standard) -> Set<String> {
        let key = "acknowledgedHangDiagnosticRequests"
        let previous = Set(defaults.stringArray(forKey: key) ?? [])
        let current = Set(requests)
        let pending = current.subtracting(previous)
        defaults.set(Array(current).sorted(), forKey: key)
        return pending
    }
}
