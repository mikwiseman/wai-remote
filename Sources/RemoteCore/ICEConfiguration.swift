import Foundation

/// Short-lived relay credentials received over the authenticated signaling connection.
/// They are held in memory, never written into an invitation or saved with a device key.
public struct ICEConfiguration: Decodable {
    public struct Server: Decodable {
        public let urls: [String]
        public let username: String
        public let credential: String
    }
    public let iceServers: [Server]
    public let iceTransportPolicy: String
    public let expiresAt: Double
    public static let local = ICEConfiguration(iceServers: [], iceTransportPolicy: "all", expiresAt: 0)
    public enum Invalid: Error { case configuration }

    public static func read(_ message: [String: Any], now: Date = Date()) throws -> ICEConfiguration {
        guard let raw = message["ice"] else { return .local }
        guard let object = raw as? [String: Any] else { throw Invalid.configuration }
        let result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
        guard result.expiresAt > now.timeIntervalSince1970,
              result.expiresAt <= now.timeIntervalSince1970 + 7200,
              ["all", "relay"].contains(result.iceTransportPolicy), (1...4).contains(result.iceServers.count),
              result.iceServers.allSatisfy({ server in
                  (1...4).contains(server.urls.count) && (1...512).contains(server.username.utf8.count) &&
                  (1...512).contains(server.credential.utf8.count) && server.urls.allSatisfy(validURL)
              }) else { throw Invalid.configuration }
        return result
    }
    private static func validURL(_ text: String) -> Bool {
        guard text.utf8.count <= 512, let colon = text.firstIndex(of: ":"),
              ["turn", "turns"].contains(String(text[..<colon])),
              let url = URLComponents(string: String(text[..<colon]) + "://" + text[text.index(after: colon)...]),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.path.isEmpty, url.fragment == nil,
              url.port == nil || (1...65535).contains(url.port!) else { return false }
        return url.query == nil || ["transport=udp", "transport=tcp"].contains(url.query!)
    }
}
