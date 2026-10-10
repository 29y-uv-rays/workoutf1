import Foundation
import CoreLocation

// MARK: - Workout source

/// Anything APEX can read completed workouts from (HealthKit in production, fixtures in DEBUG).
protocol WorkoutSource: AnyObject {
    var isHealthKitAvailable: Bool { get }
    func requestAccess() async -> HealthKitAccessResult
    /// Returns workouts started after `startDate` (full history when `nil`). De-duplication by
    /// `sourceWorkoutUUID` happens in the persistence layer, not here.
    func fetchRecords(since startDate: Date?) async throws -> [WorkoutRecord]
}

// MARK: - GPS sample

struct GPSSample: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let t: Date
    let lat: Double
    let lon: Double
    let alt: Double?
    let hAcc: Double?
    let speed: Double?

    init(id: UUID = UUID(), t: Date, lat: Double, lon: Double, alt: Double? = nil, hAcc: Double? = nil, speed: Double? = nil) {
        self.id = id; self.t = t; self.lat = lat; self.lon = lon
        self.alt = alt; self.hAcc = hAcc; self.speed = speed
    }
}

// MARK: - Workout record

struct WorkoutRecord: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let sourceWorkoutUUID: String
    let activityType: ActivityType
    let startDate: Date
    let endDate: Date
    let durationSeconds: Double
    let distanceMeters: Double
    let samples: [GPSSample]
    let hasRoute: Bool
    let pauseIntervals: [PauseInterval]

    var hasGPS: Bool { !samples.isEmpty }

    init(id: UUID = UUID(), sourceWorkoutUUID: String, activityType: ActivityType, startDate: Date, endDate: Date, durationSeconds: Double, distanceMeters: Double, samples: [GPSSample] = [], hasRoute: Bool = false, pauseIntervals: [PauseInterval] = []) {
        self.id = id; self.sourceWorkoutUUID = sourceWorkoutUUID; self.activityType = activityType
        self.startDate = startDate; self.endDate = endDate; self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters; self.samples = samples; self.hasRoute = hasRoute
        self.pauseIntervals = pauseIntervals
    }
}

struct PauseInterval: Codable, Sendable, Equatable, Hashable {
    let start: Date
    let end: Date
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    func overlaps(_ a: Date, _ b: Date, epsilon: TimeInterval = 0.01) -> Bool {
        let s = max(start, a), e = min(end, b)
        return e.timeIntervalSince(s) > epsilon
    }

    func overlapDuration(withinStart: Date, withinEnd: Date) -> Double {
        let s = max(start, withinStart), e = min(end, withinEnd)
        return max(0, e.timeIntervalSince(s))
    }
}

// MARK: - Access result

enum HealthKitAccessResult: Sendable, Equatable {
    case authorised
    case authorisedWithLimitedData
    case denied
    case notAvailable
    case error(String)
}

// MARK: - Import result

/// Outcome of one import-and-persist pass. `importedCount` counts *newly inserted* workouts.
struct WorkoutImportResult: Sendable {
    let importedCount: Int
    let withGPSCount: Int
    let latestStartDate: Date?
    let error: String?
}
