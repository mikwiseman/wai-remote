import SwiftUI
import RemoteCore

@main struct WAIRemotePhoneApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            PhoneView(model: model)
                .tint(.accentColor)
                .onOpenURL { model.open($0) }
                #if DEBUG
                .onAppear(perform: model.startDemo)
                #endif
                .onChange(of: phase) { _, value in
                    if value == .active { model.resume() }
                    if value == .inactive, model.connected { model.liftHeldInput() }
                    if value == .background, model.connected || model.connecting { model.suspend() }
                }
        }
    }
}

struct PhoneView: View {
    @ObservedObject var model: PhoneModel
    @State private var scanning = false
    var body: some View {
        ZStack {
            if model.connected { SessionView(model: model).transition(.opacity) }
            else if model.connecting { ConnectingView(model: model).transition(.opacity) }
            else { HomeView(model: model, scanning: $scanning).transition(.opacity) }
        }
        .animation(.smooth(duration: 0.35), value: model.connected)
        .animation(.smooth(duration: 0.35), value: model.connecting)
        .tint(Brand.accent)
        .sheet(isPresented: $scanning) {
            InvitationScanner { invitation in model.invitation = invitation; model.connect() }
        }
    }
}

#if DEBUG
extension PhoneModel {
    /// `-WAIDemoSession <screenshot>` opens a session on that picture with no Mac;
    /// `-WAIDemoState draw|paused|waiting|reconnecting|zoomed|typing` picks the moment. Debug builds only.
    static let demoScreen = UserDefaults.standard.string(forKey: "WAIDemoSession").flatMap(UIImage.init(contentsOfFile:))
    static let demoMoment = UserDefaults.standard.string(forKey: "WAIDemoState") ?? ""
    func startDemo() {
        guard let image = Self.demoScreen, !connected else { return }
        let moment = Self.demoMoment
        let state: [String: Any] = ["sessionID": "demo", "controllerEpoch": 0, "inputEpoch": 0, "modeGeneration": 0, "layerEpoch": 0, "reason": "",
            "nextSequence": 0, "mode": RemoteMode(rawValue: moment)?.rawValue ?? "control", "permissions": ["control": true, "annotate": true],
            "surface": ["id": "demo", "revision": 1, "width": Int(image.size.width), "height": Int(image.size.height)]]
        guard let data = try? JSONSerialization.data(withJSONObject: state), let host = try? JSONDecoder().decode(HostState.self, from: data) else { return }
        acceptDemo(host); computerName = "Студия"; connected = true; connectionInterrupted = moment == "reconnecting"
        if moment != "waiting" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.receivedFrame = true } }
    }
}
#endif
