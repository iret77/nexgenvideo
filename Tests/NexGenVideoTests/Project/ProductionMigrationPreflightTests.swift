import AppKit
import CoreFoundation
import Dispatch
import XCTest
@testable import NexGenVideo

final class ProductionMigrationPreflightTests: XCTestCase {
    @MainActor
    func testMainQueueModalShowsProgressAndReturnsTheWorkerValue() async {
        let observation = await exercise(.success)
        XCTAssertEqual(observation.panelTitle, "Verifying Project")
        XCTAssertTrue(observation.sawProgress)
        XCTAssertFalse(observation.watchdogFired)
        XCTAssertEqual(observation.value, 42)
        XCTAssertNil(observation.failure)
        XCTAssertTrue(observation.panelClosed)
    }

    @MainActor
    func testMainQueueModalPropagatesTheWorkerError() async {
        let observation = await exercise(.failure)
        XCTAssertEqual(observation.panelTitle, "Verifying Project")
        XCTAssertTrue(observation.sawProgress)
        XCTAssertFalse(observation.watchdogFired)
        XCTAssertEqual(observation.failure, .worker)
        XCTAssertTrue(observation.panelClosed)
    }

    @MainActor
    func testMainQueueModalCancelReachesTheWorkerAndClosesThePanel() async {
        let observation = await exercise(.cancel)
        XCTAssertEqual(observation.panelTitle, "Verifying Project")
        XCTAssertTrue(observation.sawProgress)
        XCTAssertTrue(observation.clickedCancel)
        XCTAssertTrue(observation.sawCancelling)
        XCTAssertFalse(observation.watchdogFired)
        XCTAssertEqual(observation.failure, .cancelled)
        XCTAssertTrue(observation.panelClosed)
    }

    @MainActor
    func testNestedModalKeepsItsSessionUntilExplicitCloseAndThenReturnsTheWorkerValue() async {
        let observation = await exercise(.nestedSuccess)
        XCTAssertTrue(observation.sawProgress)
        XCTAssertTrue(observation.completionWhileNested)
        XCTAssertTrue(observation.nestedStillCurrentBeforeExplicitClose)
        XCTAssertTrue(observation.nestedClosedAsRequested)
        XCTAssertFalse(observation.watchdogFired)
        XCTAssertEqual(observation.value, 42)
        XCTAssertNil(observation.failure)
        XCTAssertTrue(observation.panelClosed)
    }

    @MainActor
    func testNestedModalKeepsItsSessionUntilExplicitCloseAndThenReturnsTheWorkerError() async {
        let observation = await exercise(.nestedFailure)
        XCTAssertTrue(observation.sawProgress)
        XCTAssertTrue(observation.completionWhileNested)
        XCTAssertTrue(observation.nestedStillCurrentBeforeExplicitClose)
        XCTAssertTrue(observation.nestedClosedAsRequested)
        XCTAssertFalse(observation.watchdogFired)
        XCTAssertEqual(observation.failure, .worker)
        XCTAssertTrue(observation.panelClosed)
    }

    @MainActor
    private func exercise(_ mode: PreflightTestMode) async -> PreflightObservation {
        _ = NSApplication.shared
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard NSApp.modalWindow == nil else {
                    continuation.resume(returning: PreflightObservation(failure: .unexpectedModal))
                    return
                }
                let release = DispatchSemaphore(value: 0)
                let observer = PreflightPanelObserver(mode: mode, release: release)
                let timer = Timer(timeInterval: 0.01, target: observer,
                    selector: #selector(PreflightPanelObserver.observe(_:)), userInfo: nil, repeats: true)
                RunLoop.main.add(timer, forMode: .modalPanel)
                defer { timer.invalidate() }
                let result: Result<Int, Error> = Result {
                    try ProductionMigrationPreflight.perform(completionDeliveredForTesting: {
                        observer.completionDelivered()
                    }) { control in
                        control.progress(1, 2)
                        guard release.wait(timeout: .now() + 10) == .success else { throw PreflightTestFailure.workerGate }
                        try control.checkCancellation()
                        if mode == .failure || mode == .nestedFailure { throw PreflightTestFailure.worker }
                        return 42
                    }
                }
                var observation = observer.result
                observation.panelClosed = observer.panel?.isVisible != true && NSApp.modalWindow == nil
                switch result {
                case .success(let value): observation.value = value
                case .failure(is CancellationError): observation.failure = .cancelled
                case .failure(let error): observation.failure = error as? PreflightTestFailure ?? .unexpectedError
                }
                continuation.resume(returning: observation)
            }
        }
    }
}

private enum PreflightTestMode: Sendable, Equatable { case success, failure, cancel, nestedSuccess, nestedFailure }
private enum PreflightTestFailure: Error, Sendable, Equatable { case worker, workerGate, cancelled, unexpectedModal, unexpectedError }

private struct PreflightObservation: Sendable {
    var panelTitle: String?
    var sawProgress = false
    var clickedCancel = false
    var sawCancelling = false
    var watchdogFired = false
    var panelClosed = false
    var completionWhileNested = false
    var nestedStillCurrentBeforeExplicitClose = false
    var nestedClosedAsRequested = false
    var value: Int?
    var failure: PreflightTestFailure?
}

@MainActor
private final class PreflightPanelObserver: NSObject {
    let mode: PreflightTestMode
    let release: DispatchSemaphore
    let existingWindows: Set<ObjectIdentifier>
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    weak var panel: NSWindow?
    var result = PreflightObservation()
    private var released = false
    private var nestedPanel: NSPanel?

    init(mode: PreflightTestMode, release: DispatchSemaphore) {
        self.mode = mode
        self.release = release
        existingWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
    }

    func completionDelivered() {
        guard let nestedPanel, NSApp.modalWindow === nestedPanel else { return }
        result.completionWhileNested = true
        CFRunLoopPerformBlock(CFRunLoopGetMain(), RunLoop.Mode.modalPanel.rawValue as CFString) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let nestedPanel = self.nestedPanel, NSApp.modalWindow === nestedPanel else { return }
                self.result.nestedStillCurrentBeforeExplicitClose = true
                NSApp.stopModal(withCode: .OK)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func runNestedModal() {
        let nested = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        nested.title = "Nested modal regression"
        nested.contentView = NSTextField(labelWithString: "Keep this modal active until worker completion delivery.")
        nested.setContentSize(nested.contentView?.fittingSize ?? .zero)
        nested.center()
        nestedPanel = nested
        let watchdog = Timer(timeInterval: 0.01, target: self,
            selector: #selector(watchNested(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(watchdog, forMode: .modalPanel)
        defer {
            watchdog.invalidate()
            nested.orderOut(nil)
            nestedPanel = nil
        }
        release.signal()
        let response = NSApp.runModal(for: nested)
        result.nestedClosedAsRequested = response == .OK && result.nestedStillCurrentBeforeExplicitClose
    }

    @objc private func watchNested(_ timer: Timer) {
        guard ContinuousClock.now >= deadline, let nestedPanel, NSApp.modalWindow === nestedPanel else { return }
        result.watchdogFired = true
        NSApp.abortModal()
        nestedPanel.orderOut(nil)
        timer.invalidate()
    }

    @objc func observe(_ timer: Timer) {
        guard let current = NSApp.modalWindow else { return }
        guard let content = current.contentView else { return }
        var views = [content]
        var index = 0
        while index < views.count {
            views.append(contentsOf: views[index].subviews)
            index += 1
        }
        let labels = views.compactMap { $0 as? NSTextField }
        let progress = views.compactMap { $0 as? NSProgressIndicator }.first
        if panel == nil, current is NSPanel, !existingWindows.contains(ObjectIdentifier(current)), progress != nil,
           views.contains(where: { ($0 as? NSButton)?.title == "Cancel" }) {
            panel = current
            result.panelTitle = current.title
        }
        guard current === panel else { return }
        if !released, labels.contains(where: { $0.stringValue == "Verifying project files (1/2)…" }),
           progress?.doubleValue == 1, progress?.maxValue == 2, progress?.isIndeterminate == false {
            result.sawProgress = true
            if mode == .cancel, let cancel = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }) {
                cancel.performClick(nil)
                result.clickedCancel = true
                result.sawCancelling = !cancel.isEnabled && labels.contains { $0.stringValue == "Cancelling verification…" }
            }
            released = true
            if mode == .nestedSuccess || mode == .nestedFailure {
                runNestedModal()
            } else {
                release.signal()
            }
        }
        if ContinuousClock.now >= deadline {
            result.watchdogFired = true
            if !released { released = true; release.signal() }
            if NSApp.modalWindow === panel {
                NSApp.abortModal()
                panel?.orderOut(nil)
            }
            timer.invalidate()
        }
    }
}
