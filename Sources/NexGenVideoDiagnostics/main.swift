import Darwin
import Foundation
import HangDiagnostics

umask(0o077)
guard CommandLine.arguments.count == 4,
      let target = Int32(CommandLine.arguments[1]), target == getppid(),
      let startupID = UUID(uuidString: CommandLine.arguments[2]) else { exit(64) }
let session = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
guard session.lastPathComponent == startupID.uuidString,
      session.resolvingSymlinksInPath() == session.standardizedFileURL else { exit(65) }

struct CaptureStatus: Codable {
    let schema = 1
    let startupID: UUID
    let detectedUptime: Double
    var recoveredUptime: Double?
    var samples: [String] = []
    var processLost = false
}

func capture(number: Int, incident: URL) -> String {
    guard getppid() == target else { return "target-exited" }
    let file = incident.appendingPathComponent("threads-\(number).sample.txt")
    let sample = Process()
    let completed = DispatchSemaphore(value: 0)
    sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    sample.arguments = [String(target), "3", "-mayDie", "-file", file.path]
    sample.standardOutput = FileHandle.nullDevice
    sample.standardError = FileHandle.nullDevice
    sample.terminationHandler = { _ in completed.signal() }
    do {
        try sample.run()
        if completed.wait(timeout: .now() + 8) != .success {
            sample.terminate()
            if completed.wait(timeout: .now() + 1) != .success { kill(sample.processIdentifier, SIGKILL) }
            return "timeout"
        }
        guard sample.terminationStatus == 0,
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 100 else { return "failed-\(sample.terminationStatus)" }
        return "captured"
    } catch { return "launch-failed" }
}

var state = DiagnosticHangState()
var incident: URL?
var status: CaptureStatus?
var incidentCount = 0
let started = ProcessInfo.processInfo.systemUptime
var lastHeartbeat: DiagnosticHeartbeat?
while true {
    let now = ProcessInfo.processInfo.systemUptime
    if getppid() != target {
        if var final = status, let incident {
            final.processLost = true
            try? DiagnosticFiles.replace(final, at: incident.appendingPathComponent("incident.json"))
        }
        exit(0)
    }
    if let bytes = try? Data(contentsOf: session.appendingPathComponent("heartbeat.json")),
       let pulse = try? JSONDecoder().decode(DiagnosticHeartbeat.self, from: bytes),
       pulse.startupID == startupID, pulse.processID == target {
        lastHeartbeat = pulse
    }
    if lastHeartbeat?.stopped == true { exit(0) }
    switch state.tick(now: now, mainUptime: lastHeartbeat?.mainUptime ?? started) {
    case .pin:
        guard incidentCount < 3 else { continue }
        let folder = session.appendingPathComponent("incident-\(UUID().uuidString)")
        do {
            try DiagnosticFiles.directory(folder)
            try DiagnosticFiles.replace(true, at: session.appendingPathComponent("pinned.json"))
            incident = folder
            incidentCount += 1
            status = CaptureStatus(startupID: startupID, detectedUptime: now)
            try DiagnosticFiles.replace(status, at: folder.appendingPathComponent("incident.json"))
        } catch { exit(74) }
    case .sample(let number):
        if let incident {
            let request = UUID().uuidString
            try? DiagnosticFiles.replace(request, at: session.appendingPathComponent("sample-request.json"))
            status?.samples.append("self-\(request):requested-\(number)")
            try? DiagnosticFiles.replace(status, at: incident.appendingPathComponent("incident.json"))
        }
    case .recovered, .suspended:
        if let incident {
            status?.recoveredUptime = now
            try? DiagnosticFiles.replace(status, at: incident.appendingPathComponent("incident.json"))
        }
        incident = nil
        status = nil
    case nil: break
    }
    Thread.sleep(forTimeInterval: 0.5)
}
