import Foundation

enum ProviderStatusSignal {
    // Task-local so a status poll reaches only the host run that started it; unstructured child tasks inherit it.
    @TaskLocal static var observer: (@Sendable () -> Void)?

    static func confirmRunning() {
        observer?()
    }
}
