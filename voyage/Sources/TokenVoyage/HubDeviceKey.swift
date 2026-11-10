import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The anonymous Hub identity is separate from the quota providers' login credentials.
/// Nothing is read or generated until the first enabled, signed request.
enum HubDeviceKey {
    static let service = "local.tokenfrog.voyage"
    static let account = "voyage-hub-device-key"

    static func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let data = try read() {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        var attributes = identity
        attributes[kSecValueData] = key.rawRepresentation
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let data = try read() {
            // Another process may have created the identity after our initial read.
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecSuccess else { throw KeyError.unavailable(status) }
        return key
    }

    private static var identity: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private static func read() throws -> Data? {
        var query = identity
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeyError.unavailable(status)
        }
        return data
    }

    enum KeyError: Error { case unavailable(OSStatus) }
}

/// Signs the body bytes already attached to the request. Never re-encode after signing.
enum HubRequestSigner {
    static func canonicalString(for request: URLRequest, timestamp: Int64) throws -> String {
        guard timestamp >= 0, let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw HubClientError.invalidRequest
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let pathWithQuery = components.percentEncodedQuery.map { path + "?" + $0 } ?? path
        let hash = SHA256.hash(data: request.httpBody ?? Data()).map { String(format: "%02x", $0) }.joined()
        return "\((request.httpMethod ?? "GET").uppercased())\n\(pathWithQuery)\n\(timestamp)\n\(hash)"
    }

    static func signed(_ request: URLRequest, privateKey: Curve25519.Signing.PrivateKey,
                       timestamp: Int64) throws -> URLRequest {
        let canonical = try canonicalString(for: request, timestamp: timestamp)
        var signed = request
        signed.httpMethod = (request.httpMethod ?? "GET").uppercased()
        signed.setValue(privateKey.publicKey.rawRepresentation.base64EncodedString(), forHTTPHeaderField: "X-Voyage-Device")
        signed.setValue(String(timestamp), forHTTPHeaderField: "X-Voyage-Timestamp")
        signed.setValue(try privateKey.signature(for: Data(canonical.utf8)).base64EncodedString(),
                        forHTTPHeaderField: "X-Voyage-Signature")
        return signed
    }
}
