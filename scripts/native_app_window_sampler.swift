import AppKit
import CoreGraphics
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else { exit(2) }
let folder = URL(fileURLWithPath: arguments[0], isDirectory: true)
let output = folder.appendingPathComponent("windows.jsonl")
guard FileManager.default.createFile(atPath: output.path, contents: nil),
      let file = try? FileHandle(forWritingTo: output) else { exit(3) }
let began = ProcessInfo.processInfo.systemUptime
var bytes = 0
var samples = 0
var reason = "stop"
var failed = false
var lastSampleTime = 0.0
do {
    while true {
        if ProcessInfo.processInfo.systemUptime - began >= 150 { reason = "timeout"; break }
        let finalSample = FileManager.default.fileExists(atPath: folder.appendingPathComponent("stop").path)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let screens: [[String: Any]] = NSScreen.screens.map { screen in
            let frame = screen.frame
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let bounds = number.map { CGDisplayBounds($0.uint32Value) }
            return ["appKitFrame": [frame.minX, frame.minY, frame.width, frame.height],
                "backingScaleFactor": screen.backingScaleFactor, "displayID": number as Any? ?? NSNull(),
                "quartzBounds": bounds.map { [$0.minX, $0.minY, $0.width, $0.height] } as Any? ?? NSNull()]
        }
        lastSampleTime = Date().timeIntervalSince1970
        let row: [String: Any] = ["schema": "native-window-server-observation/v1", "sample": samples,
            "observerPID": ProcessInfo.processInfo.processIdentifier, "wallTime": lastSampleTime,
            "uptime": ProcessInfo.processInfo.systemUptime, "screens": screens,
            "screenCapturePreflight": CGPreflightScreenCaptureAccess(),
            "windowListAvailable": windows != nil, "orderedRawWindows": windows as Any? ?? NSNull()]
        let raw = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([0x0A])
        if bytes + raw.count > 256 * 1024 * 1024 { reason = "output-cap"; break }
        try file.write(contentsOf: raw)
        try file.synchronize()
        bytes += raw.count
        if samples == 0 {
            let ready = try JSONSerialization.data(withJSONObject: ["firstSample": 0, "bytes": bytes,
                "wallTime": lastSampleTime, "uptime": ProcessInfo.processInfo.systemUptime], options: [.sortedKeys])
            try ready.write(to: folder.appendingPathComponent("ready.json"), options: .withoutOverwriting)
        }
        samples += 1
        if finalSample { break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    try file.synchronize()
    try file.close()
} catch {
    reason = "error: \(error)"
    failed = true
}
let complete = samples > 0 && reason == "stop" && !failed
let receipt: [String: Any] = ["samples": samples, "bytes": bytes, "reason": reason,
    "observerPID": ProcessInfo.processInfo.processIdentifier, "endedWallTime": Date().timeIntervalSince1970,
    "lastSampleWallTime": lastSampleTime,
    "endedUptime": ProcessInfo.processInfo.systemUptime, "complete": complete,
    "inputEventsPosted": false, "applicationActivated": false,
    "limit": "External WindowServer samples do not expose the private in-process pointer guard read."]
do {
    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        .write(to: folder.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
} catch { exit(4) }
exit(complete ? 0 : 1)
