import SwiftUI
import SwiftData

@main
struct APEXApp: App {
    @State private var appState = AppStateModel()
    let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(persistence)
                .modelContainer(persistence.container)
        }
    }
}

struct RootView: View {
    @Environment(AppStateModel.self) private var appState

    var body: some View {
        Group {
            if appState.onboardingComplete == false {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .animation(.default, value: appState.onboardingComplete)
    }
}

struct MainTabView: View {
    @State private var selectedTab = Tab.home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            CircuitsView()
                .tabItem { Label("Circuits", systemImage: "figure.run.circle.fill") }
                .tag(Tab.circuits)

            LapsView()
                .tabItem { Label("Laps", systemImage: "timer") }
                .tag(Tab.laps)
        }
        .tint(Theme.purple)
    }
}

enum Tab { case home, circuits, laps }

// MARK: - AppState (SwiftData single row)

@Model
final class AppStateModel {
    @Attribute(.unique) var id: UUID
    var healthKitAnchor: Data?
    var lastSyncDate: Date?
    var onboardingComplete: Bool
    var autoSync: Bool

    init(id: UUID = UUID(), healthKitAnchor: Data? = nil, lastSyncDate: Date? = nil, onboardingComplete: Bool = false, autoSync: Bool = true) {
        self.id = id
        self.healthKitAnchor = healthKitAnchor
        self.lastSyncDate = lastSyncDate
        self.onboardingComplete = onboardingComplete
        self.autoSync = autoSync
    }
}
