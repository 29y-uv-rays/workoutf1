import HealthKit
import Foundation
import CoreLocation
import SwiftUI

// MARK: - Errors

enum HealthKitImportError: LocalizedError, Sendable {
    case unavailable
    case notAuthorised

    var errorDescription: String? {
        switch self {
        case .unavailable: return "HealthKit is not available on this device."
        case .notAuthorised: return "APEX does not have Apple Health access. Open Settings and allow APEX to read workouts."
        }
    }
}

// MARK: - HealthKit service

actor HealthKitService: WorkoutSource {
    static let shared = HealthKitService()

    private let hk = HKHealthStore()
    private var workoutsWithNoRoute: Set<String> = []

    private init() {}

    // MARK: - WorkoutSource

    nonisolated var isHealthKitAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAccess() async -> HealthKitAccessResult {
        guard isHealthKitAvailable else { return .notAvailable }
        do {
            let read: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
            try await hk.requestAuthorization(toShare: [], read: read)
            enableBackgroundDeliveryIfPossible()
            return .authorised
        } catch {
            return .error(error.localizedDescription)
        }
    }

    func fetchRecords(since startDate: Date?) async throws -> [WorkoutRecord] {
        guard isHealthKitAvailable else { throw HealthKitImportError.unavailable }
        if hk.authorizationStatus(for: HKObjectType.workoutType()) == .sharingDenied {
            throw HealthKitImportError.notAuthorised
        }

        let workouts = try await queryWorkouts(since: startDate)
        var records: [WorkoutRecord] = []
        records.reserveCapacity(workouts.count)
        for workout in workouts {
            let samples = (try? await routeSamples(for: workout)) ?? []

            if samples.isEmpty { workoutsWithNoRoute.insert(workout.uuid.uuidString) }
            records.append(WorkoutRecord(
                sourceWorkoutUUID: workout.uuid.uuidString,
                activityType: Self.mapActivity(workout.workoutActivityType),
                startDate: workout.startDate,
                endDate: workout.endDate,
                durationSeconds: workout.duration,
                distanceMeters: workout.totalDistance?.doubleValue(for: .meter()) ?? 0,
                samples: samples,
                hasRoute: !samples.isEmpty,
                pauseIntervals: Self.pauseIntervals(from: workout)
            ))
        }
        return records
    }

    // MARK: - Status

    /// Read permission cannot be re-queried, so this reports the stored status for the workout
    /// type. Nonisolated so Settings can read it synchronously.
    nonisolated func currentStatus() -> HealthKitStatus {
        guard HKHealthStore.isHealthDataAvailable() else {
            return HealthKitStatus(kind: .unavailable, text: "HealthKit is not available on this device.", needsAuth: true, allowedSync: false, isSyncing: false, showMissingGPSGuide: false)
        }
        let status = HKHealthStore().authorizationStatus(for: HKObjectType.workoutType())
        guard status == .sharingAuthorized else {
            return HealthKitStatus(kind: .notAuthorised, text: "HealthKit access not granted. Allow APEX to read workouts to import your sessions.", needsAuth: true, allowedSync: false, isSyncing: false, showMissingGPSGuide: false)
        }
        return HealthKitStatus(kind: .authorised, text: "Connected to Apple Health.", needsAuth: false, allowedSync: true, isSyncing: false, showMissingGPSGuide: false)
    }

    // MARK: - Background delivery

    nonisolated func enableBackgroundDeliveryIfPossible() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        // Registering an HKObserverQuery + enableBackgroundDelivery(for:) is a device-only step;
        // APEX refreshes on launch as the reliable path (see DEVICE_TESTING.md).
    }

    // MARK: - Queries

    private func queryWorkouts(since startDate: Date?) async throws -> [HKWorkout] {
        let predicate: NSPredicate
        if let startDate {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForWorkouts(with: [.running, .walking, .cycling]),
                NSPredicate(format: "startDate > %@", startDate as NSDate)
            ])
        } else {
            predicate = HKQuery.predicateForWorkouts(with: [.running, .walking, .cycling])
        }
        let sort = [HKSampleSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            hk.execute(query)
        }
    }

    /// Loads the GPS route attached to a workout (if any) as APEX samples.
    private func routeSamples(for workout: HKWorkout) async throws -> [GPSSample] {
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkoutRoute], Error>) in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            hk.execute(query)
        }
        guard let route = routes.first else { return [] }

        let state = RouteQueryState()
        let locations: [CLLocation] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CLLocation], Error>) in

            let query = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                state.append(batch)
                if let error {
                    if state.settle() != nil { continuation.resume(throwing: error) }
                    return
                }
                if done, let all = state.settle() {
                    continuation.resume(returning: all)
                }
            }
            hk.execute(query)
        }

        return locations.map { location in
            GPSSample(
                t: location.timestamp,
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude,
                alt: location.altitude,
                hAcc: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                speed: location.speed >= 0 ? location.speed : nil
            )
        }
    }

    // MARK: - Mapping helpers

    private static func mapActivity(_ type: HKWorkoutActivityType) -> ActivityType {
        switch type {
        case .running: return .run
        case .walking: return .walk
        case .cycling: return .cycle
        default: return .run
        }
    }

    /// HealthKit records pause/resume as discrete events; turn them into intervals the timing
    /// engine subtracts from lap time.
    private static func pauseIntervals(from workout: HKWorkout) -> [PauseInterval] {
        let events = (workout.workoutEvents as [HKWorkoutEvent]?) ?? []
        var intervals: [PauseInterval] = []
        var pauseStart: Date?
        for event in events {
            switch event.type {
            case .pause:
                pauseStart = event.dateInterval.start
            case .resume:
                if let start = pauseStart {
                    intervals.append(PauseInterval(start: start, end: event.dateInterval.start))
                    pauseStart = nil
                }
            default:
                break
            }
        }
        if let start = pauseStart {
            intervals.append(PauseInterval(start: start, end: workout.endDate))
        }
        return intervals
    }

    // MARK: - Dedup bookkeeping

    func recordNoRoute(workoutUUID: String) {
        workoutsWithNoRoute.insert(workoutUUID)
    }

    func hasRoute(workoutUUID: String) -> Bool {
        !workoutsWithNoRoute.contains(workoutUUID)
    }
}

// MARK: - Route query state

/// Accumulates route location batches and settles a continuation exactly once.
private final class RouteQueryState: @unchecked Sendable {
    private let lock = NSLock()
    private var locations: [CLLocation] = []
    private var settled = false

    func append(_ batch: [CLLocation]?) {
        lock.lock()
        if let batch { locations.append(contentsOf: batch) }
        lock.unlock()
    }

    /// Returns the accumulated locations the first time it is called, `nil` after that.
    func settle() -> [CLLocation]? {
        lock.lock()
        defer { lock.unlock() }
        if settled { return nil }
        settled = true
        return locations
    }
}

// MARK: - HealthKit status

struct HealthKitStatus: Sendable {
    var kind: Kind
    var text: String
    var needsAuth: Bool
    var allowedSync: Bool
    var isSyncing: Bool
    var showMissingGPSGuide: Bool
}

extension HealthKitStatus {
    enum Kind: Sendable {
        case authorised
        case notAuthorised
        case unavailable

        var color: Color {
            switch self {
            case .authorised: return Theme.green
            case .notAuthorised: return Theme.yellow
            case .unavailable: return Theme.grey
            }
        }

        var label: String {
            switch self {
            case .authorised: return "Connected"
            case .notAuthorised: return "Not connected"
            case .unavailable: return "Unavailable"
            }
        }
    }
}
