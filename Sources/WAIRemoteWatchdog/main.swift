import AppKit
import Darwin

// A small login agent supervises this exact signed bundle. It neither captures
// the screen nor accepts connections. Closing access leaves it dormant.
// SMAppService supplies a bundle-relative argv[0] with '/' as the working
// directory. dyld knows the actual installed executable, including app moves.
var pathSize: UInt32 = 0
_ = _NSGetExecutablePath(nil, &pathSize)
var pathBuffer = [CChar](repeating: 0, count: Int(pathSize))
guard _NSGetExecutablePath(&pathBuffer, &pathSize) == 0 else { exit(EX_CONFIG) }
let executable = URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath()
let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let preferencesDomain = "is.wai.remote.dev" as CFString
var missingSince: Date?
var launching = false
func inspect() {
    // This executable lives inside the host bundle, so its suite name can equal
    // the main bundle ID (UserDefaults(suiteName:) then returns nil). Read the
    // exact domain and refresh the cross-process cache instead.
    CFPreferencesAppSynchronize(preferencesDomain)
    guard CFPreferencesCopyAppValue("persistentScreenAccess" as CFString, preferencesDomain) != nil else { missingSince = nil; return }
    let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == appURL.standardizedFileURL.path }
    if running { missingSince = nil; return }
    if missingSince == nil { missingSince = Date(); return }
    // Give Sparkle time to replace and relaunch the bundle itself.
    guard !launching, Date().timeIntervalSince(missingSince!) >= 20,
          FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/MacOS/WAIRemote").path) else { return }
    launching = true
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.arguments = ["--background"]
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
        DispatchQueue.main.async { launching = false; missingSince = Date() }
    }
}
Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in inspect() }
inspect()
RunLoop.main.run()
