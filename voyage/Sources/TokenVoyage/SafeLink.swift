import Foundation

enum SafeLink {
    static func url(_ value: String) -> URL? {
        guard value.count <= 2_048, let url = URL(string: value),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func host(_ host: String, belongsTo domain: String) -> Bool {
        let host = host.lowercased()
        return host == domain || host.hasSuffix(".\(domain)")
    }
}
