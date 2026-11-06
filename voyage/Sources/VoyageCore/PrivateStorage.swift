import Foundation

/// Files shared by saves, import transactions and photos use the same private permissions.
public enum PrivateStorage {
    public static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func secureFile(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) throws {
        try data.write(to: url, options: options)
        // An atomic write installs a new inode with its own default permissions.
        try secureFile(at: url)
    }

    /// Best-effort startup repair; inspect metadata only and never follow links out of the data tree.
    static func repairPermissions(in directory: URL) {
        let files = FileManager.default
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = files.enumerator(at: directory, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in true }) else { return }
        for case let url as URL in entries {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                entries.skipDescendants()
            } else if values.isDirectory == true {
                try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } else if values.isRegularFile == true {
                try? secureFile(at: url)
            }
        }
    }
}
