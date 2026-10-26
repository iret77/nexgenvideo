import Foundation

public struct BpyRuntimeBundleLayout: Sendable {
    public let service: URL
    public let runtime: URL
    public let supervisor: URL
    public let compliance: URL

    public init(app: URL, serviceName: String) throws {
        let app = app.resolvingSymlinksInPath()
        guard let slot = bpyRuntimeServiceNames.firstIndex(of: serviceName) else {
            throw CocoaError(.fileReadNoPermission)
        }
        service = app.appendingPathComponent("Contents/XPCServices/NexGenVideoBpyService\(slot).xpc")
        runtime = service.appendingPathComponent("Contents/Resources/BpyRuntime")
        supervisor = service.appendingPathComponent("Contents/MacOS/NexGenVideoBpySupervisor")
        compliance = app.appendingPathComponent("Contents/Resources/BpyRuntimeCompliance")
    }
}
