import AppKit
import ServiceManagement

/// The owner's choice outlives a transport, a locked screen and an app update.
/// Window grants remain tied to the original process, never to a reused PID.
struct PersistentAccess: Codable, Equatable {
    enum Target: Codable, Equatable {
        case display
        case window(pid: pid_t, id: CGWindowID, launchedAt: Date, boot: String)
    }
    let target: Target
    static let key = "persistentScreenAccess"
    static func read(from defaults: UserDefaults = .standard) -> Self? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    static func save(_ value: Self?, to defaults: UserDefaults = .standard) {
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

enum BackgroundAccess {
    static let agentName = "is.wai.remote.recovery.plist"
    static func enable() -> String? {
        // Command-line tests and development executables must not register jobs.
        guard Bundle.main.bundleURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Contents/Library/LaunchAgents/" + agentName) else { return nil }
        do {
            let service = SMAppService.agent(plistName: agentName)
            if service.status == .notRegistered || service.status == .notFound { try service.register() }
            if service.status == .requiresApproval { return "Разрешите WAI Remote работать в фоне в настройках входа macOS." }
            if service.status != .enabled { return "Фоновый запуск пока недоступен. Оставьте WAI Remote открытым." }
        } catch { return "Не удалось включить запуск в фоне: \(error.localizedDescription)" }
        return nil
    }
    static func disable() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.agent(plistName: agentName)
        if service.status == .enabled || service.status == .requiresApproval { try? service.unregister() }
    }
}
