import Darwin
import Foundation
import VoyageCore

/// Only called by the quota runtime after consent. Dependencies never probe the machine at init.
struct LocalCredentials: Sendable {
    typealias Reader = @Sendable (QuotaSource) async throws -> QuotaCredential
    var codexDirectory: @Sendable () -> URL = {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    var claudeDirectory: @Sendable () -> URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    var readFile: @Sendable (URL) async throws -> Data = { url in
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try Data(contentsOf: url)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    var readKeychain: @Sendable () async throws -> Data = {
        try await MemoryCommand.run(executable: URL(fileURLWithPath: "/usr/bin/security"),
                                    arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 10)
    }

    func read(_ source: QuotaSource) async throws -> QuotaCredential {
        try Task.checkCancellation()
        do {
            switch source {
            case .codex:
                return try Self.codex(try await readFile(codexDirectory().appendingPathComponent("auth.json")))
            case .claude:
                if let data = try? await readKeychain(), let credential = try? Self.claude(data) {
                    try Task.checkCancellation()
                    return credential
                }
                try Task.checkCancellation()
                return try Self.claude(try await readFile(claudeDirectory().appendingPathComponent(".credentials.json")))
            case .otherTools:
                throw QuotaProviderError.missingLogin
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // File paths, process output and DecodingError contexts must not cross this boundary.
            throw QuotaProviderError.missingLogin
        }
    }

    static func codex(_ data: Data) throws -> QuotaCredential {
        struct Login: Decodable {
            struct Tokens: Decodable { let access_token: String; let account_id: String? }
            let tokens: Tokens
        }
        do {
            let login = try JSONDecoder().decode(Login.self, from: data)
            guard !login.tokens.access_token.isEmpty else { throw QuotaProviderError.missingLogin }
            return QuotaCredential(accessToken: login.tokens.access_token, accountID: login.tokens.account_id)
        } catch { throw QuotaProviderError.missingLogin }
    }

    static func claude(_ data: Data) throws -> QuotaCredential {
        struct Login: Decodable {
            struct OAuth: Decodable { let accessToken: String }
            let claudeAiOauth: OAuth
        }
        do {
            let login = try JSONDecoder().decode(Login.self, from: data)
            guard !login.claudeAiOauth.accessToken.isEmpty else { throw QuotaProviderError.missingLogin }
            return QuotaCredential(accessToken: login.claudeAiOauth.accessToken)
        } catch { throw QuotaProviderError.missingLogin }
    }
}

/// Captures stdout in a pipe, never a temporary file; stderr is discarded.
enum MemoryCommand {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        let command = RunningMemoryCommand(executable: executable, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try command.run(timeout: timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { command.cancel() }
    }
}

private final class RunningMemoryCommand: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
    }

    func run(timeout: TimeInterval) throws -> Data {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            do { try process.run() }
            catch { throw UsageError.failed(-1) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.stop(timedOut: true)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try lock.withLock {
            if cancelled { throw CancellationError() }
            if timedOut { throw UsageError.timedOut }
            guard process.terminationStatus == 0 else { throw UsageError.failed(process.terminationStatus) }
            return data
        }
    }

    func cancel() { stop(timedOut: false) }

    private func stop(timedOut: Bool) {
        lock.withLock {
            if timedOut { self.timedOut = true } else { cancelled = true }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
