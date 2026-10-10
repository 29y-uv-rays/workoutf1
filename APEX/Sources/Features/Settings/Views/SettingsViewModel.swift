import SwiftUI
import SwiftData

@Observable
final class SettingsViewModel {
    private let appState: AppStateModel
    private let modelContext: ModelContext
    private let persistence: PersistenceController

    var healthKitStatus: HealthKitStatus?
    var keyStatus: KeychainStatus?
    var isSyncing = false
    var keyValidating = false
    var showDeleteConfirmation = false

    init(appState: AppStateModel, modelContext: ModelContext, persistence: PersistenceController) {
        self.appState = appState
        self.modelContext = modelContext
        self.persistence = persistence
        refresh()
    }

    func refresh() {
        let status = HealthKitService.shared.currentStatus()
        // Surface the missing-GPS guide whenever some imported workouts have no route.
        if status.kind == .authorised {
            let workouts = (try? modelContext.fetch(FetchDescriptor<Workout>())) ?? []
            status.showMissingGPSGuide = workouts.contains { $0.timingStatus == .missingGPS }
        }
        healthKitStatus = status
        if let key = KeychainService.shared.geminiKey, !key.isEmpty {
            keyStatus = KeychainStatus(label: "Key stored", color: Theme.green)
        } else {
            keyStatus = KeychainStatus(label: "No key set", color: Theme.secondaryText)
        }
    }

    @MainActor
    func manualSync() async {
        refresh()
        guard healthKitStatus?.allowedSync == true else { return }
        isSyncing = true
        defer { isSyncing = false }
        let result = await HealthKitOnboarding.importAndPersist(
            since: appState.lastSyncDate,
            modelContext: modelContext,
            fileStore: persistence.fileStore
        )
        if result.error == nil {
            appState.lastSyncDate = Date()
            try? modelContext.save()
        }
        refresh()
    }

    @MainActor
    func validateGeminiKey() async {
        keyValidating = true
        defer { keyValidating = false }
        let key = KeychainService.shared.geminiKey
        let id = KeychainService.shared.geminiModelID ?? GeminiService.defaultModelID
        let result = await GeminiService.shared.validateKey(key: key, modelID: id)
        switch result {
        case .ok: keyStatus = KeychainStatus(label: "Key valid", color: Theme.green)
        case .invalidKey: keyStatus = KeychainStatus(label: "Invalid API key (401/403)", color: .red)
        case .modelNotFound: keyStatus = KeychainStatus(label: "Model not found — edit Model ID in Settings", color: .red)
        case .rateLimited: keyStatus = KeychainStatus(label: "Rate limited (429)", color: Theme.yellow)
        case .networkError, .noKey: keyStatus = KeychainStatus(label: key == nil ? "No key set" : "Network error", color: Theme.secondaryText)
        }
    }

    @MainActor
    func performDeleteAll() async {
        showDeleteConfirmation = false
        do {
            try persistence.clearAllData()
            appState.healthKitAnchor = nil
            appState.lastSyncDate = nil
            appState.onboardingComplete = false
            try modelContext.save()
        } catch {
            // handled
        }
    }
}
