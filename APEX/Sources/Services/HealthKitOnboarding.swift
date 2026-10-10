import Foundation
import SwiftData
import CoreLocation

struct HealthKitOnboarding {
    static let shared = HealthKitOnboarding()
    private init() {}

    static func requestAccess() async -> HealthKitAccessResult {
        await HealthKitService.shared.requestAccess()
    }

    /// Fetches workouts started after `startDate` from Apple Health and persists the new ones.
    ///
    /// Routes are written to Application Support through `FileStore`; workouts without a route are
    /// stored as `.missingGPS` so they still appear (as "No Telemetry") instead of disappearing.
    @MainActor
    @discardableResult
    static func importAndPersist(since startDate: Date?, modelContext: ModelContext, fileStore: FileStore) async -> WorkoutImportResult {
        do {
            let records = try await HealthKitService.shared.fetchRecords(since: startDate)
            let existing = Set(((try? modelContext.fetch(FetchDescriptor<Workout>())) ?? []).map(\.sourceWorkoutUUID))
            var imported = 0
            var withGPS = 0
            for record in records where !existing.contains(record.sourceWorkoutUUID) {
                let fileName = record.hasGPS ? fileStore.writeRouteJSON(record.samples, for: record.sourceWorkoutUUID) : nil
                modelContext.insert(Workout(
                    sourceWorkoutUUID: record.sourceWorkoutUUID,
                    activityType: record.activityType,
                    startDate: record.startDate,
                    endDate: record.endDate,
                    durationSeconds: record.durationSeconds,
                    distanceMeters: record.distanceMeters,
                    routeFile: fileName,
                    timingStatus: record.hasGPS ? .pending : .missingGPS
                ))
                imported += 1
                if record.hasGPS { withGPS += 1 }
            }
            if imported > 0 { try modelContext.save() }
            return WorkoutImportResult(importedCount: imported, withGPSCount: withGPS, latestStartDate: records.map(\.startDate).max(), error: nil)
        } catch {
            return WorkoutImportResult(importedCount: 0, withGPSCount: 0, latestStartDate: nil, error: error.localizedDescription)
        }
    }
}
