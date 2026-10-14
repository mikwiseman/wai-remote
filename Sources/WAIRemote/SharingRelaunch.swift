import AppKit
import Darwin
import Security

/// One update handoff, never an unattended-access preference.
struct SharingRelaunch: Codable {
    enum Target: Codable, Equatable {
        case display(CGDirectDisplayID)
        case window(pid: pid_t, id: CGWindowID, launchedAt: Date)
    }

    private let target: Target
    private let createdAt: Date
    private let build: String
    private let bootSession: String
    private static let key = "sharingAfterUpdate"
    static var currentBuild: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }

    static var currentBootSession: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        var session = SecuritySessionId(0)
        guard SessionGetInfo(callerSecuritySession, &session, nil) == errSecSuccess else { return nil }
        return "\(String(cString: bytes)):\(session)"
    }

    static var sessionActive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true &&
            session[kCGSessionLoginDoneKey as String] as? Bool == true &&
            session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    static func save(_ target: Target?, defaults: UserDefaults = .standard, now: Date = Date(),
                     build: String? = currentBuild, bootSession: String? = currentBootSession) {
        defaults.removeObject(forKey: key)
        guard let target, let build, let bootSession else { return }
        let value = SharingRelaunch(target: target, createdAt: now, build: build, bootSession: bootSession)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    static func take(defaults: UserDefaults = .standard, now: Date = Date(),
                     build: String? = currentBuild, bootSession: String? = currentBootSession,
                     sessionActive: Bool = sessionActive) -> Target? {
        defer { defaults.removeObject(forKey: key) }
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data),
              let build, build.compare(value.build, options: .numeric) == .orderedDescending,
              let bootSession, bootSession == value.bootSession,
              sessionActive, (0...300).contains(now.timeIntervalSince(value.createdAt)) else { return nil }
        return value.target
    }
}
