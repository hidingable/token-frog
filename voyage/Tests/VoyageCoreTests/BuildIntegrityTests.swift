import Foundation
import Testing

@Suite struct BuildIntegrityTests {
    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/build-app.sh")
    }

    private func function(_ name: String) throws -> String {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let start = try #require(script.range(of: "\(name)() {"))
        let end = try #require(script.range(of: "\n}", range: start.upperBound..<script.endIndex))
        return String(script[start.lowerBound..<end.upperBound])
    }

    private func bash(_ code: String, arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", code, "integrity-test"] + arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func verifiedFilesPassAndChangedOrMissingFilesFail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("downloaded resource")
        try Data("verified resource\n".utf8).write(to: file)
        // SHA-256 of this fixed fixture, independent of the production resources.
        let hash = "596f57f6c19b6875a3b8028089a69a134a2ab4ab12a32cef67f9b72bd50dc81f"
        let verifier = try function("verify_sha256")
        let code = "set -euo pipefail\n\(verifier)\nverify_sha256 \"$1\" \"$2\""
        let good = try bash(code, arguments: [file.path, hash])
        #expect(good.0 == 0, "\(good.1)")
        try Data("modified resource\n".utf8).write(to: file)
        let changed = try bash(code, arguments: [file.path, hash])
        #expect(changed.0 != 0 && changed.1.contains("SHA-256 mismatch"))
        let missing = try bash(code, arguments: [directory.appendingPathComponent("missing").path, hash])
        #expect(missing.0 != 0 && missing.1.contains("Missing verified resource"))
    }

    @Test func failedVerificationRemovesDownloadTemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("untrusted download".utf8).write(to: directory.appendingPathComponent("resource"))
        let code = """
        set -euo pipefail
        \(try function("verify_sha256"))
        \(try function("cleanup_temp"))
        TMP="$1"
        trap cleanup_temp EXIT
        verify_sha256 "$TMP/resource" "invalid-checksum"
        """
        let result = try bash(code, arguments: [directory.path])
        #expect(result.0 != 0 && result.1.contains("SHA-256 mismatch"))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
