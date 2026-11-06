import Foundation
import VoyageCore

enum UsageError: Error {
    case missingBinary
    case failed(Int32)
    case timedOut
}

/// Runs `tokscale graph` for a date range. Offline and low priority; the caller keeps scans serial.
enum UsageSource {
    static func binaryURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["TOKEN_VOYAGE_TOKSCALE"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("tokscale/tokscale")
    }

    /// `since` nil reads the whole history.
    static func fetch(since: String?, until: String) async throws -> [DayDetail] {
        let output = temporaryFile()
        defer { try? FileManager.default.removeItem(at: output) }
        let range = since.map { ["--since", $0] } ?? []
        try await run(["graph", "--offline", "--no-spinner", "--until", until, "--output", output.path] + range)
        return try TokscaleGraph.parseDetails(Data(contentsOf: output))
    }

    static func fetchHours(since: String, until: String) async throws -> [HourUsage] {
        let output = temporaryFile()
        defer { try? FileManager.default.removeItem(at: output) }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try await run(["hourly", "--json", "--offline", "--no-spinner", "--since", since, "--until", until], standardOutput: handle)
        return try TokscaleHourly.parse(Data(contentsOf: output))
    }

    /// Unlike usage scans this reaches the providers, using the credentials tokscale finds on this Mac.
    static func fetchQuotas() async throws -> [ProviderQuota] {
        let output = temporaryFile()
        defer { try? FileManager.default.removeItem(at: output) }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try await run(["usage", "--json"], standardOutput: handle)
        return try QuotaReport.parse(Data(contentsOf: output))
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("token-voyage-\(UUID().uuidString).json")
    }

    static func run(_ arguments: [String], standardOutput: FileHandle = .nullDevice, executable: URL? = nil) async throws {
        try Task.checkCancellation()
        guard let binary = executable ?? binaryURL(), FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw UsageError.missingBinary
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        let box = ProcessBox(process)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try box.start()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { box.terminateIfRunning() }
            }
        } onCancel: {
            box.cancel()
        }
        try Task.checkCancellation()
        if status == SIGTERM { throw UsageError.timedOut }
        guard status == 0 else { throw UsageError.failed(status) }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false
    init(_ process: Process) { self.process = process }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    func terminateIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning { process.terminate() }
    }
}

/// Watches tool session folders so scans only run when something actually changed.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor @Sendable () -> Void

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    static func existingRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ".claude/projects", ".codex/sessions", ".codex/archived_sessions", ".gemini/tmp", ".local/share/opencode",
            ".hermes", ".copilot", ".qwen", ".kimi", ".pi", ".factory", ".openclaw",
        ]
        .map { "\(home)/\($0)" }
        .filter { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        let roots = Self.existingRoots()
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }
}
