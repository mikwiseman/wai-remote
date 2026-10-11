import Foundation

public struct RemoteInvite {
    public let hostID: String
    public let publicKey: String
    public let secret: Data?
    public let signalingURL: URL
    public let savedURL: URL

    public enum Invalid: Error { case invitation }

    public static func phoneURL(for invitation: String) -> URL? {
        guard (try? RemoteInvite(invitation)) != nil else { return nil }
        var url = URLComponents(); url.scheme = "wai-remote"; url.host = "connect"
        url.queryItems = [URLQueryItem(name: "invite", value: invitation)]
        return url.url
    }

    public init(_ text: String) throws {
        guard text.utf8.count <= 4096, var url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw Invalid.invitation }
        var fields = URLComponents(); fields.percentEncodedQuery = url.percentEncodedFragment
        let items = fields.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { throw Invalid.invitation }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let host = values["host"], let key = values["key"], let keyData = Data(base64URL: key), keyData.count == 65,
              DeviceIdentity.id(publicKeyData: keyData) == host else { throw Invalid.invitation }
        var pairing: Data?
        if let value = values["secret"] {
            guard let data = Data(base64URL: value), data.count == 32 else { throw Invalid.invitation }; pairing = data
        }
        url.fragment = nil
        guard let base = url.url, Self.isAllowedGateway(base) else { throw Invalid.invitation }
        hostID = host; publicKey = key; secret = pairing
        let path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = path.isEmpty ? "/" : "/" + path + "/"
        url.scheme = base.scheme == "https" ? "wss" : "ws"; url.path = basePath + "signal"
        guard let signal = url.url else { throw Invalid.invitation }; signalingURL = signal
        url.scheme = base.scheme; url.path = basePath
        fields.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "key", value: key)]
        url.percentEncodedFragment = fields.percentEncodedQuery
        guard let saved = url.url else { throw Invalid.invitation }; savedURL = saved
    }

    // Signatures bind the pinned device to both SDP fingerprints. LAN HTTP carries discovery metadata only.
    // Internet endpoints still require HTTPS; WebRTC media and commands are encrypted on every route.
    public static func isAllowedGateway(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !url.path.contains("\\"), url.path.utf8.count <= 200 else { return false }
        if url.scheme == "https" { return true }
        guard url.scheme == "http" else { return false }
        if ["localhost", "[::1]", "::1"].contains(host) || host.hasSuffix(".local") { return true }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              pieces.compactMap({ UInt8($0) }).count == 4 else { return false }
        let bytes = pieces.compactMap { UInt8($0) }
        return bytes[0] == 127 || bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 172 && (16...31).contains(bytes[1]))
    }
}
