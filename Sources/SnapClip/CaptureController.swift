import AppKit
import SnapClipCore

/// Runs `screencapture` for the hotkey and the floating button. One capture at a time.
@MainActor
final class CaptureController {
    private let folder: () -> URL
    private let onRunningChanged: (Bool) -> Void
    private var isRunning = false

    /// `onRunningChanged(true)` fires when a capture starts and `false` when it ends.
    init(folder: @escaping () -> URL, onRunningChanged: @escaping (Bool) -> Void) {
        self.folder = folder
        self.onRunningChanged = onRunningChanged
    }

    func capture() {
        guard !isRunning else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CaptureCommand.executable)
        process.arguments = CaptureCommand.arguments(folder: folder(), date: Date())
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.finish(status: status) }
        }
        isRunning = true
        onRunningChanged(true)
        do {
            try process.run()
        } catch {
            NSLog("SnapClip: could not start screencapture: %@", String(describing: error))
            finish(status: 0)
        }
    }

    private func finish(status: Int32) {
        // Esc to cancel exits 0 without writing a file; only a non-zero exit is a failure.
        if status != 0 { NSLog("SnapClip: screencapture exited with status %d", status) }
        isRunning = false
        onRunningChanged(false)
    }
}
