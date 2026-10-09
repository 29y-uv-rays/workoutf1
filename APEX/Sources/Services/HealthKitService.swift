import HealthKit
import Foundation

actor HealthKitService: WorkoutSource {
    static let shared = HealthKitService()

    private let hk = HKHealthStore()
    private var isAuthorised = false

    init() {}

    nonisolated var isHealthKitAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAccess() async -> HealthKitAccessResult {
        guard isHealthKitAvailable else { return .notAvailable }
        let types: Set<HKObjectType> = [HKObjectType.workoutType(), HKWorkoutRouteSeriesType()]
        do {
            try await hk.requestAuthorization(toShare: nil, read: types)
            isAuthorised = true
            return .authorised
        } catch {
            return .error(error.localizedDescription)
        }
    }

    func importAll() -> WorkoutImportStream {
        WorkoutImportStreamImpl {
            nil // real implementation fetches and persists; for M0/M3 scaffolding returns empty on first call
        }
    }

    func importSince(startDate: Date?) async -> WorkoutImportResult {
        guard isAuthorised else {
            return WorkoutImportResult(importedCount: 0, withGPSCount: 0, latestStartDate: nil, error: "HealthKit not authorised")
        }
        // Real implementation uses an anchored query; for M0 we report 0 new.
        return WorkoutImportResult(importedCount: 0, withGPSCount: 0, latestStartDate: nil, error: nil)
    }

    func currentStatus() -> HealthKitStatusView {
        guard isHealthKitAvailable else {
            return HealthKitStatusView(kind: .unavailable, text: "HealthKit is not available on this device.", needsAuth: true, allowedSync: false, isSyncing: false, showMissingGPSGuide: false)
        }
        if !isAuthorised {
            return HealthKitStatusView(kind: .unavailable, text: "HealthKit access not granted. Open Settings to enable APEX to read workouts.", needsAuth: true, allowedSync: false, isSyncing: false, showMissingGPSGuide: false)
        }
        return HealthKitStatusView(kind: .authorised, text: "Connected to Apple Health.", needsAuth: false, allowedSync: true, isSyncing: false, showMissingGPSGuide: false)
    }

    nonisolated func enableBackgroundDeliveryIfPossible() {
        // Best-effort; HKObserverQuery would be used here in a real build.
    }
}

struct HealthKitStatusView: Sendable {
    let kind: HealthKitStatus.Kind
    let text: String
    let needsAuth: Bool
    let allowedSync: Bool
    let isSyncing: Bool
    let showMissingGPSGuide: Bool
}
