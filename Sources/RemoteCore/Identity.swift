import Foundation
import CryptoKit

public extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        guard base64URL.utf8.count <= 200_000 else { return nil }
        let s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4))
    }
}

public struct DeviceIdentity {
    private let key: P256.Signing.PrivateKey
    public init() { key = P256.Signing.PrivateKey() }
    public init(rawPrivateKey: Data) throws { key = try P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey) }
    public var privateKey: Data { key.rawRepresentation }
    public var publicKey: String { key.publicKey.x963Representation.base64URL }
    public var id: String { Self.id(publicKeyData: key.publicKey.x963Representation) }
    public static func id(publicKeyData: Data) -> String { SHA256.hash(data: publicKeyData).map { String(format: "%02x", $0) }.joined() }
    public func sign(_ data: Data, domain: String) throws -> String {
        try key.signature(for: Data((domain + "\0").utf8) + data).rawRepresentation.base64URL
    }
    public static func verify(_ signature: String, data: Data, domain: String, publicKey: String) -> Bool {
        guard let keyData = Data(base64URL: publicKey), let sigData = Data(base64URL: signature),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigData) else { return false }
        return key.isValidSignature(sig, for: Data((domain + "\0").utf8) + data)
    }
    public static func pairingProof(secret: Data, payload: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data("wai-remote/pair/v1\0".utf8) + payload, using: SymmetricKey(data: secret))).base64URL
    }
    public static func verifyPairingProof(_ proof: String, secret: Data, payload: Data) -> Bool {
        guard let mac = Data(base64URL: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data("wai-remote/pair/v1\0".utf8) + payload, using: SymmetricKey(data: secret))
    }
}
