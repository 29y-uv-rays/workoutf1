import Foundation
import CoreLocation

// MARK: - GPS sample

struct GPSSample: Codable, Sendable, Identifiable {
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
        self.distanceMeters = distanceMeters; self.samples = samples; self.hasRoute = hasRoute; self.pauseIntervals = pauseIntervals
    }
}

struct PauseInterval: Codable, Sendable, Equatable {
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

// MARK: - Import stream

struct WorkoutImportStream: Sequence, Sendable {
    struct Element: Sendable {
        let phase: Phase
        let importedCount: Int
        let withGPSCount: Int

        enum Phase: Sendable, Equatable {
            case starting
            case importing(batchIndex: Int, totalBatches: Int?)
            case finished(importedCount: Int, withGPSCount: Int)
            case cancelled
            case empty(reason: String)
            case error(String)
        }
    }

    typealias Iterator = IteratorImpl
    func makeIterator() -> Iterator
}

final class WorkoutImportStreamImpl: IteratorProtocol, Sequence {
    typealias Element = WorkoutImportStream.Element
    private var state: WorkoutImportStream.Element?
    private let makeNext: () -> WorkoutImportStream.Element?

    init(makeNext: @escaping () -> WorkoutImportStream.Element?) {
        self.makeNext = makeNext
        self.state = makeNext()
    }

    func makeIterator() -> Iterator { self }

    func next() -> Element? {
        defer { state = makeNext() }
        return state
    }
}

struct WorkoutImportResult: Sendable {
    let importedCount: Int
    let withGPSCount: Int
    let latestStartDate: Date?
    let error: String?
}
