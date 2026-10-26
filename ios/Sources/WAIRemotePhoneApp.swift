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
                .onChange(of: phase) { _, value in
                    if value == .active { model.resume() }
                    if value == .inactive, model.connected { model.releaseInput() }
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
