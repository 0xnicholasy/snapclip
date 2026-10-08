import Foundation

public enum UpgradeOutcome: Sendable, Equatable {
    case success
    case failed(String)
}

public final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isSet: Bool { lock.withLock { value } }
    public func set() { lock.withLock { value = true } }
}

/// The slice of Foundation's `Process` the upgrade runner drives, so tests can substitute a fake.
public protocol UpgradeProcess: AnyObject, Sendable {
    func run() throws
    func waitUntilExit()
    func interrupt()
    func terminate()
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
}

public protocol UpgradeProcessLauncher: Sendable {
    /// Builds an unstarted process that runs `executable` with `arguments`, writing stdout and stderr to `log`.
    func makeProcess(
        executable: URL, arguments: [String], environment: [String: String], log: FileHandle
    ) -> UpgradeProcess
}

/// The only place the upgrade flow creates a Foundation `Process`.
public struct SystemUpgradeProcessLauncher: UpgradeProcessLauncher {
    // Process is not Sendable; the runner only starts and waits on it from one thread, and the watchdog only terminates it.
    private final class SystemProcess: UpgradeProcess, @unchecked Sendable {
        let process = Process()
        func run() throws { try process.run() }
        func waitUntilExit() { process.waitUntilExit() }
        func interrupt() { process.interrupt() }
        func terminate() { process.terminate() }
        var isRunning: Bool { process.isRunning }
        var terminationStatus: Int32 { process.terminationStatus }
    }

    public init() {}

    public func makeProcess(
        executable: URL, arguments: [String], environment: [String: String], log: FileHandle
    ) -> UpgradeProcess {
        let wrapper = SystemProcess()
        let process = wrapper.process
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        return wrapper
    }
}

public enum UpgradeRunner {
    /// Runs `brew update --quiet` then `brew upgrade snapclip`, logging to `logURL` (overwritten).
    public static func run(
        _ homebrew: HomebrewInstall,
        logURL: URL,
        timeout: TimeInterval,
        launcher: UpgradeProcessLauncher = SystemUpgradeProcessLauncher(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> UpgradeOutcome {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard isExecutable(homebrew.brewPath) else {
                return .failed("Homebrew was not found at \(homebrew.brewPath)")
            }
            guard fm.createFile(atPath: logURL.path, contents: nil) else {
                return .failed("Could not create \(logURL.path)")
            }
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let steps = [["update", "--quiet"], ["upgrade", "snapclip"]]
            for arguments in steps {
                try log.write(contentsOf: Data("$ brew \(arguments.joined(separator: " "))\n".utf8))
                let process = launcher.makeProcess(
                    executable: URL(fileURLWithPath: homebrew.brewPath),
                    arguments: arguments,
                    environment: homebrew.environment,
                    log: log)
                try process.run()
                let timedOut = TimeoutFlag()
                let watchdog = DispatchWorkItem {
                    timedOut.set()
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                process.waitUntilExit()
                watchdog.cancel()
                if timedOut.isSet { return .failed("Update timed out") }
                if process.terminationStatus != 0 {
                    return .failed("brew \(arguments[0]) exited with status \(process.terminationStatus)")
                }
            }
            return .success
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
