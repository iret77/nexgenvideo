import AppKit
import CryptoKit
import CoreFoundation
import Darwin
import Foundation

@MainActor
final class ProductionMigrationPreflight: NSObject {
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        let progress: @Sendable (Int, Int) -> Void

        init(progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) { self.progress = progress }
        func cancel() { lock.withLock { cancelled = true } }
        func checkCancellation() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }

        func digest(_ url: URL) throws -> String {
            try checkCancellation()
            guard url.resolvingSymlinksInPath() == url.standardizedFileURL else { throw ProductionWorkflowRecoveryMigration.MigrationError.invalidSource }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let before = try stamp(handle)
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                try checkCancellation()
                hash.update(data: bytes)
            }
            try checkCancellation()
            let current = try FileHandle(forReadingFrom: url)
            defer { try? current.close() }
            guard try stamp(handle) == before, try stamp(current) == before,
                  url.resolvingSymlinksInPath() == url.standardizedFileURL else {
                throw ProductionWorkflowRecoveryMigration.MigrationError.changedSource
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        private func stamp(_ handle: FileHandle) throws -> [Int64] {
            var value = stat()
            guard fstat(handle.fileDescriptor, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
            return [Int64(value.st_dev), Int64(bitPattern: value.st_ino), value.st_size,
                Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
                Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
        }

    }

    private final class Completion<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error>?
        func set(_ result: Result<T, Error>) { lock.withLock { value = result } }
        func get() -> Result<T, Error>? { lock.withLock { value } }
    }

    private let panel: NSPanel
    private let indicator = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Verifying project files…")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var control: Control?
    private var finished = false

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        indicator.isIndeterminate = true
        indicator.style = .bar
        label.font = .systemFont(ofSize: AppTheme.FontSize.sm)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        let stack = NSStackView(views: [label, indicator, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AppTheme.Spacing.md
        stack.edgeInsets = NSEdgeInsets(top: AppTheme.Spacing.lg, left: AppTheme.Spacing.lg,
                                       bottom: AppTheme.Spacing.lg, right: AppTheme.Spacing.lg)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            indicator.widthAnchor.constraint(equalToConstant: AppTheme.ComponentSize.packInstallProgressWindow.width)
        ])
        panel.contentView = content
        panel.title = "Verifying Project"
        panel.hidesOnDeactivate = false
    }

    nonisolated static func perform<T: Sendable>(
        completionDeliveredForTesting: (@MainActor @Sendable () -> Void)? = nil,
        _ operation: @escaping @Sendable (Control) throws -> T
    ) throws -> T {
        guard Thread.isMainThread else { return try operation(Control()) }
        return try MainActor.assumeIsolated {
            guard NSApp != nil else { return try operation(Control()) }
            let view = ProductionMigrationPreflight()
            let completion = Completion<T>()
            let control = Control { [weak view] completed, count in
                deliverToModalLoop { [weak view] in view?.update(completed, total: count) }
            }
            view.control = control
            let completionObserver = CFRunLoopObserverCreateWithHandler(nil,
                CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak view] _, _ in
                MainActor.assumeIsolated {
                    if completion.get() != nil { view?.finishIfCurrent() }
                }
            }
            if let completionObserver {
                CFRunLoopAddObserver(CFRunLoopGetMain(), completionObserver, RunLoop.Mode.modalPanel.rawValue as CFString)
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak view] in
                completion.set(Result { try operation(control) })
                deliverToModalLoop { [weak view] in
                    guard let view, !view.finished else { return }
                    completionDeliveredForTesting?()
                    view.finishIfCurrent()
                }
            }
            view.panel.setContentSize(view.panel.contentView?.fittingSize ?? .zero)
            view.panel.center()
            defer {
                if let completionObserver { CFRunLoopObserverInvalidate(completionObserver) }
                if !view.finished { control.cancel() }
                view.finished = true
                view.control = nil
                view.panel.orderOut(nil)
            }
            NSApp.runModal(for: view.panel)
            guard let result = completion.get() else { throw CancellationError() }
            return try result.get()
        }
    }

    // Modal completion must not depend on reentering the main dispatch queue.
    nonisolated private static func deliverToModalLoop(_ action: @escaping @MainActor @Sendable () -> Void) {
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, RunLoop.Mode.modalPanel.rawValue as CFString) {
            MainActor.assumeIsolated { action() }
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func finishIfCurrent() {
        guard !finished, NSApp.modalWindow === panel else { return }
        finished = true
        NSApp.stopModal()
        panel.orderOut(nil)
    }

    private func update(_ completed: Int, total: Int) {
        guard !finished else { return }
        indicator.isIndeterminate = total == 0
        indicator.maxValue = Double(max(1, total))
        indicator.doubleValue = Double(completed)
        if cancelButton.isEnabled { label.stringValue = "Verifying project files (\(completed)/\(total))…" }
    }

    @objc private func cancel() {
        control?.cancel()
        cancelButton.isEnabled = false
        label.stringValue = "Cancelling verification…"
    }
}
