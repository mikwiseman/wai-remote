import Foundation
import Security
import RemoteCore

struct TrustedPeer: Codable, Identifiable {
    var id: String
    var publicKey: String
    var name: String
    var permissions: Permissions
    var labOnly: Bool
}

enum KeyStore {
    static func identity() throws -> DeviceIdentity {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "is.wai.remote.identity", kSecAttrAccount as String: "host",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try DeviceIdentity(rawPrivateKey: data) }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let identity = DeviceIdentity()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "is.wai.remote.identity", kSecAttrAccount as String: "host",
            kSecValueData as String: identity.privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return identity
    }
    static var peersURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WAI Remote", isDirectory: true).appendingPathComponent("peers.json")
    }
    static func peers() -> [TrustedPeer] {
        guard let data = try? Data(contentsOf: peersURL) else { return [] }
        return (try? JSONDecoder().decode([TrustedPeer].self, from: data)) ?? []
    }
    static func save(_ peers: [TrustedPeer]) throws {
        try FileManager.default.createDirectory(at: peersURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(peers).write(to: peersURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: peersURL.path)
    }
}
