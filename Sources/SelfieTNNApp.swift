import SwiftUI

@main
struct SelfieTNNApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lock = AppLock.shared

    init() { PasscodeStore.ensureDefault() }

    var body: some Scene {
        WindowGroup {
            // Content is not even built while locked, so the camera never runs behind the lock.
            Group {
                if lock.isLocked { Color.black.ignoresSafeArea() } else { ContentView() }
            }
            .onAppear { LockWindowController.shared.install() }
            .onChange(of: scenePhase) { _, phase in lock.scenePhaseChanged(phase) }
        }
    }
}
