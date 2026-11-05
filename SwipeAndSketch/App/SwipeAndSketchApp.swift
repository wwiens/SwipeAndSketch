import SwiftUI

@main struct SwipeAndSketchApp: App {
    @StateObject private var session = ModelingSession(inMemory: true)
    @State private var home = HomeController()
    @Environment(\.scenePhase) private var scenePhase
    init() {
        #if DEBUG
        // XCUITest can wait indefinitely for iPadOS context-menu animations to quiesce.
        // This opt-in affects only the dedicated menu test, never normal app launches.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-no-animations") {
            UIView.setAnimationsEnabled(false)
        }
        #endif
        // Operation bars' segmented choices take the brand: the chosen one in Swipe Violet.
        let segments = UISegmentedControl.appearance()
        segments.selectedSegmentTintColor = UIColor(named: "ss-violet")
        segments.setTitleTextAttributes([.foregroundColor: UIColor(named: "ss-paper") ?? .white], for: .selected)
        segments.setTitleTextAttributes([.foregroundColor: UIColor(named: "ss-ink") ?? .black], for: .normal)
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if ModelingSession.isRunningUITests { WorkspaceView(session: session) }
                else { HomeScreen(controller: home).ignoresSafeArea().onOpenURL { home.openExternal($0) } }
            }
            .preferredColorScheme(.light)
            .onChange(of: scenePhase) { _, phase in if phase != .active { home.autosaveActiveProject() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    AppAccessStore.shared.refreshClock()
                    Task { await AppAccessStore.shared.refresh() }
                }
            }
        }
    }
}
