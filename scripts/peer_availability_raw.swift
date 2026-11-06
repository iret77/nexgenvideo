import ApplicationServices
import CryptoKit
import Darwin
import Foundation

@main
private struct PeerAvailabilityRaw {
    private final class Reader {
        let seconds: Float
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var messages: [[String: Any]] = []

        init(seconds: Float) { self.seconds = seconds }

        func pid(_ element: AXUIElement) -> (pid_t?, Int32?) {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                messages.append(["attribute": "pid", "deadlineExceeded": true])
                return (nil, nil)
            }
            let timeout = min(seconds, Float(remaining))
            let timeoutStatus = AXUIElementSetMessagingTimeout(element, timeout)
            guard timeoutStatus == .success else {
                messages.append(["attribute": "pid", "timeoutStatus": timeoutStatus.rawValue])
                return (nil, nil)
            }
            let started = ProcessInfo.processInfo.systemUptime
            var owner: pid_t = 0
            let status = AXUIElementGetPid(element, &owner)
            messages.append(["attribute": "pid", "timeout": timeout, "timeoutStatus": timeoutStatus.rawValue,
                "started": started, "finished": ProcessInfo.processInfo.systemUptime, "status": status.rawValue])
            return (status == .success ? owner : nil, status.rawValue)
        }

        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                messages.append(["attribute": name, "deadlineExceeded": true])
                return nil
            }
            let timeout = min(seconds, Float(remaining))
            let timeoutStatus = AXUIElementSetMessagingTimeout(element, timeout)
            guard timeoutStatus == .success else {
                messages.append(["attribute": name, "timeoutStatus": timeoutStatus.rawValue])
                return nil
            }
            let started = ProcessInfo.processInfo.systemUptime
            var result: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            messages.append(["attribute": name, "timeout": timeout, "timeoutStatus": timeoutStatus.rawValue,
                "started": started, "finished": ProcessInfo.processInfo.systemUptime, "status": status.rawValue])
            return status == .success ? result : nil
        }
    }

    static func observe(pid: Int32, seconds: Float, context: String, window: Int, frame: [Double]) throws -> [String: Any] {
        guard pid == getppid() else { throw NSError(domain: "AvailabilityParent", code: 1) }
        let owner = try NativeAXPeer.Identity.read(pid), own = try NativeAXPeer.Identity.read(getpid())
        let image = try NativeAXPeer.Image.current()
        let ownerBytes = try Data(contentsOf: URL(fileURLWithPath: owner.executable), options: .mappedIfSafe)
        let ownerSHA = SHA256.hash(data: ownerBytes).map { String(format: "%02x", $0) }.joined()
        let started = ProcessInfo.processInfo.systemUptime
        let app = AXUIElementCreateApplication(pid)
        let reader = Reader(seconds: seconds)
        let trustedBefore = AXIsProcessTrusted()
        let raw = reader.value(app, kAXWindowsAttribute)
        let trustedAfter = AXIsProcessTrusted()
        let first = reader.messages.first ?? [:]
        var windows: [[String: Any]] = []
        var validArray = false
        if let raw, CFGetTypeID(raw) == CFArrayGetTypeID() {
            let entries = raw as! [CFTypeRef]
            validArray = entries.count <= 128 && entries.allSatisfy { CFGetTypeID($0) == AXUIElementGetTypeID() }
            if validArray {
                for entry in entries {
                    let element = entry as! AXUIElement
                    let (owner, ownerStatus) = reader.pid(element)
                    let role = reader.value(element, kAXRoleAttribute) as? String
                    let position = reader.value(element, kAXPositionAttribute)
                    let size = reader.value(element, kAXSizeAttribute)
                    var point = CGPoint.zero, dimensions = CGSize.zero
                    let pointValid = position.map {
                        CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetType($0 as! AXValue) == .cgPoint
                            && AXValueGetValue($0 as! AXValue, .cgPoint, &point)
                    } ?? false
                    let sizeValid = size.map {
                        CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetType($0 as! AXValue) == .cgSize
                            && AXValueGetValue($0 as! AXValue, .cgSize, &dimensions)
                    } ?? false
                    let values = [Double(point.x), Double(point.y), Double(dimensions.width), Double(dimensions.height)]
                    let valid = pointValid && sizeValid && values.allSatisfy(\.isFinite)
                        && dimensions.width > 0 && dimensions.height > 0
                    windows.append(["PID": owner as Any? ?? NSNull(), "PIDStatus": ownerStatus as Any? ?? NSNull(),
                        "role": role as Any? ?? NSNull(), "positionTyped": pointValid, "sizeTyped": sizeValid,
                        "frame": valid ? values as Any : NSNull(),
                        "matchesRequestedFrame": valid && zip(values, frame).allSatisfy { abs($0.0 - $0.1) <= 0.5 }])
                }
            }
        }
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let cg = entries.compactMap { entry -> [String: Any]? in
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  CFGetTypeID(owner) != CFBooleanGetTypeID(), owner.doubleValue.isFinite,
                  owner.doubleValue > 1, owner.doubleValue <= Double(Int32.max),
                  owner.doubleValue.rounded(.towardZero) == owner.doubleValue else {
                return ["PID": NSNull(), "number": NSNull(), "bounds": NSNull(), "onscreen": NSNull(),
                    "unknownOwner": true]
            }
            guard owner.int32Value == pid else { return nil }
            return ["PID": owner, "number": entry[kCGWindowNumber as String] as Any? ?? NSNull(),
                "bounds": entry[kCGWindowBounds as String] as Any? ?? NSNull(),
                "onscreen": entry[kCGWindowIsOnscreen as String] as Any? ?? NSNull()]
        }
        guard pid == getppid(), try NativeAXPeer.Identity.read(pid) == owner,
              try NativeAXPeer.Identity.read(getpid()) == own else { throw NSError(domain: "AvailabilityParent", code: 2) }
        return ["schema": "nexgenvideo/peer-availability-raw/1", "readerPID": getpid(), "parentPID": getppid(),
            "targetPID": pid, "context": context, "mainThread": Thread.isMainThread,
            "ownerStart": owner.start, "ownerExecutable": owner.executable, "ownerSHA256": ownerSHA,
            "readerStart": own.start, "readerExecutable": own.executable,
            "imagePath": image.path, "imageUUID": image.uuid, "imageSHA256": image.SHA256,
            "AXTrustedBefore": trustedBefore, "AXTrustedAfter": trustedAfter,
            "AXTrusted": trustedBefore && trustedAfter, "seconds": seconds, "started": started,
            "finished": ProcessInfo.processInfo.systemUptime, "AXWindowsCall": first,
            "timeoutStatus": first["timeoutStatus"] as Any? ?? NSNull(),
            "AXWindowsStatus": first["status"] as Any? ?? NSNull(), "messages": reader.messages,
            "requestedWindow": window, "requestedFrame": frame,
            "validWindowArray": validArray, "windows": windows, "CGWindows": cg]
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 8, let pid = Int32(args[0]), pid > 1,
              ["main", "background"].contains(args[1]), ["0.15", "1"].contains(args[2]),
              let seconds = Float(args[2]), let window = Int(args[3]), window > 0 else { exit(2) }
        let frame = args.dropFirst(4).compactMap(Double.init)
        guard frame.count == 4, frame.allSatisfy(\.isFinite), frame[2] > 0, frame[3] > 0 else { exit(2) }
        let operation: @Sendable () -> Void = {
            do {
                let value = try observe(pid: pid, seconds: seconds, context: args[1], window: window, frame: frame)
                let raw = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                try FileHandle.standardOutput.write(contentsOf: raw + Data([10]))
                exit(0)
            } catch { exit(3) }
        }
        if args[1] == "main" { operation() }
        else {
            DispatchQueue.global(qos: .userInitiated).async(execute: operation)
            dispatchMain()
        }
    }
}
