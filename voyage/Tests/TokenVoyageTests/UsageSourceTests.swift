import Foundation
import Testing
@testable import TokenVoyage

@Test func cancellingAUsageReadTerminatesItsSubprocess() async throws {
    let directory = LocalizationTestFiles.root.appendingPathComponent(".build/usage-cancellation/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("started")
    let script = directory.appendingPathComponent("fake-usage")
    // exec gives the task a single sleeping subprocess to cancel, with no real usage or credentials.
    try Data("#!/bin/sh\n: > \"$1\"\nexec /bin/sleep 10\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let task = Task { try await UsageSource.run([marker.path], executable: script) }
    defer { task.cancel() }
    let startedBy = ContinuousClock.now.advanced(by: .seconds(10))
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < startedBy {
        try await Task.sleep(for: .milliseconds(5))
    }
    guard FileManager.default.fileExists(atPath: marker.path) else {
        Issue.record("The usage subprocess did not write its startup marker within 10 seconds")
        return
    }
    let cancelledAt = ContinuousClock.now
    task.cancel()
    do {
        try await task.value
        Issue.record("Cancelling a running read must throw CancellationError")
    } catch is CancellationError {
        #expect(cancelledAt.duration(to: .now) < .seconds(3))
    }
}
