import Foundation
import CoreLocation

#if DEBUG

// MARK: - Seeded RNG

enum SeededRNG {
    static func next(seed: inout UInt64) -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 31) / Double(1 << 33)
    }
    static func next(in range: ClosedRange<Double>, seed: inout UInt64) -> Double {
        range.lowerBound + next(seed: &seed) * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Route generator

struct SeededRouteGenerator {
    struct Params {
        let distanceMeters: Double
        let baseLat: Double
        let baseLon: Double
        let numPoints: Int
        let pointSpacingMeters: Double
        let selfProximityMeters: Double
        let latJitter: Double
        let lonJitter: Double
    }

    static let defaultParams = Params(
        distanceMeters: 5000.0,
        baseLat: 51.5074,
        baseLon: -0.1278,
        numPoints: 400,
        pointSpacingMeters: 12.5,
        selfProximityMeters: 12.0,
        latJitter: 0.00035,
        lonJitter: 0.00035
    )

    static func generateLoop(params: Params, seed: inout UInt64) -> [(lat: Double, lon: Double)] {
        let n = params.numPoints
        var points: [(lat: Double, lon: Double)] = []
        for i in 0..<n {
            let t = Double(i) / Double(n)
            let angle = 2.0 * .pi * t
            let r1 = params.distanceMeters / (2.0 * .pi) * 1.0
            let r2 = params.distanceMeters / (2.0 * .pi) * 0.55
            let x = r1 * cos(angle) + r2 * cos(2.0 * angle) * 0.25
            let y = r2 * sin(2.0 * angle) * 0.35 + r1 * sin(angle) * 0.7
            let lat = params.baseLat + y / 111320.0
            let lon = params.baseLon + x / (111320.0 * cos(params.baseLat * .pi / 180.0))
            let jLat = SeededRNG.next(in: -params.latJitter...params.latJitter, seed: &seed)
            let jLon = SeededRNG.next(in: -params.lonJitter...params.lonJitter, seed: &seed)
            points.append((lat: lat + jLat, lon: lon + jLon))
        }
        // nudge last point toward first so S/F proximity holds.
        if let first = points.first, let last = points.last {
            let d = haversine(first.lat, first.lon, last.lat, last.lon)
            if d > params.selfProximityMeters {
                let frac = (d - params.selfProximityMeters) / d
                points[points.count - 1] = (last.lat + (first.lat - last.lat) * frac, last.lon + (first.lon - last.lon) * frac)
            }
        }
        return points
    }

    static func length(points: [(lat: Double, lon: Double)]) -> Double {
        var len: Double = 0
        for i in 1..<points.count {
            len += haversine(points[i-1].lat, points[i-1].lon, points[i].lat, points[i].lon)
        }
        return len
    }

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371000.0
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let a = sin(dLat/2) * sin(dLat/2) + cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) * sin(dLon/2) * sin(dLon/2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - Fixture generator

struct DebugFixtureGenerator {
    static func generate(seed: UInt64 = 12345) -> DebugFixtureSet {
        var s = seed
        let loopPoints = SeededRouteGenerator.generateLoop(params: SeededRouteGenerator.defaultParams, seed: &s)
        let loopDist = SeededRouteGenerator.length(points: loopPoints)

        let loopWorkouts: [WorkoutRecord] = (0..<8).map { i in
            var localSeed = s
            let base = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86400 * 3)
            let paceMinPerKm = SeededRNG.next(in: 3.5...5.5, seed: &localSeed)
            let startOffsetFrac = SeededRNG.next(in: -0.05...0.05, seed: &localSeed)
            let jitter = SeededRNG.next(in: 2.0...8.0, seed: &localSeed)
            let samples = makeSamples(points: loopPoints, base: base, paceMinPerKm: paceMinPerKm, startOffsetFrac: startOffsetFrac, jitter: jitter, seed: &localSeed)
            let pauses: [PauseInterval] = (i == 3) ? [PauseInterval(start: base.addingTimeInterval(120), end: base.addingTimeInterval(180))] : []
            return WorkoutRecord(id: UUID(), sourceWorkoutUUID: "debug-loop-\(i)", activityType: .run, startDate: samples.first?.t ?? base, endDate: samples.last?.t ?? base, durationSeconds: samples.last?.t.timeIntervalSince(samples.first?.t ?? base) ?? 0, distanceMeters: loopDist, samples: samples, hasRoute: true, pauseIntervals: pauses)
        }

        // Point-to-point (open) ~2 km.
        let ptParams = SeededRouteGenerator.Params(distanceMeters: 2000.0, baseLat: 51.5074, baseLon: -0.1278, numPoints: 160, pointSpacingMeters: 12.5, selfProximityMeters: 1000, latJitter: 0.0003, lonJitter: 0.0003)
        var ptSeed = s
        var ptPoints = SeededRouteGenerator.generateLoop(params: ptParams, seed: &ptSeed)
        if ptPoints.count > 1 { ptPoints.removeLast() }
        let ptDist = SeededRouteGenerator.length(points: ptPoints)
        let ptSamples = ptPoints.enumerated().map { i, p in
            GPSSample(id: UUID(), t: (ptPoints.first?.t ?? Date()).addingTimeInterval(Double(i) * 5.0), lat: p.lat, lon: p.lon, alt: nil, hAcc: 7.0, speed: 2.5)
        }
        let pt = WorkoutRecord(id: UUID(), sourceWorkoutUUID: "debug-pt", activityType: .run, startDate: ptSamples.first?.t ?? Date(), endDate: ptSamples.last?.t ?? Date(), durationSeconds: ptSamples.last?.t.timeIntervalSince(ptSamples.first?.t ?? Date()) ?? 0, distanceMeters: ptDist, samples: ptSamples, hasRoute: true, pauseIntervals: [])

        // Reverse direction on main loop.
        var revSeed = s
        let revSamples = makeSamples(points: loopPoints.reversed(), base: Date(timeIntervalSince1970: 1_700_000_000 + 86400 * 30), paceMinPerKm: 4.5, startOffsetFrac: 0.02, jitter: 6.0, seed: &revSeed)
        let rev = WorkoutRecord(id: UUID(), sourceWorkoutUUID: "debug-reverse", activityType: .run, startDate: revSamples.first?.t ?? Date(), endDate: revSamples.last?.t ?? Date(), durationSeconds: revSamples.last?.t.timeIntervalSince(revSamples.first?.t ?? Date()) ?? 0, distanceMeters: loopDist, samples: revSamples, hasRoute: true, pauseIntervals: [])

        // No route.
        let noRoute = WorkoutRecord(id: UUID(), sourceWorkoutUUID: "debug-no-route", activityType: .walk, startDate: Date(timeIntervalSince1970: 1_700_000_000 + 86400 * 40), endDate: Date(timeIntervalSince1970: 1_700_000_000 + 86400 * 40 + 1800), durationSeconds: 1800, distanceMeters: 0, samples: [], hasRoute: false, pauseIntervals: [])

        // Dropout.
        var dropoutSamples = makeSamples(points: loopPoints, base: Date(timeIntervalSince1970: 1_700_000_000 + 86400 * 50), paceMinPerKm: 5.0, startOffsetFrac: 0.0, jitter: 4.0, seed: &s)
        if dropoutSamples.count > 180 {
            let removeUpTo = dropoutSamples.count / 3
            let keepFrom = removeUpTo + 20
            let gapStart = dropoutSamples[removeUpTo - 1].t
            for idx in keepFrom..<dropoutSamples.count {
                let dt = dropoutSamples[idx].t.timeIntervalSince(gapStart)
                dropoutSamples[idx] = GPSSample(id: dropoutSamples[idx].id, t: gapStart.addingTimeInterval(dt + 40), lat: dropoutSamples[idx].lat, lon: dropoutSamples[idx].lon, alt: dropoutSamples[idx].alt, hAcc: dropoutSamples[idx].hAcc, speed: dropoutSamples[idx].speed)
            }
            dropoutSamples.removeSubrange(removeUpTo..<keepFrom)
        }
        let dropout = WorkoutRecord(id: UUID(), sourceWorkoutUUID: "debug-dropout", activityType: .run, startDate: dropoutSamples.first?.t ?? Date(), endDate: dropoutSamples.last?.t ?? Date(), durationSeconds: dropoutSamples.last?.t.timeIntervalSince(dropoutSamples.first?.t ?? Date()) ?? 0, distanceMeters: loopDist, samples: dropoutSamples, hasRoute: true, pauseIntervals: [])

        // Too long.
        var tooLong = makeSamples(points: loopPoints, base: Date(timeIntervalSince1970: 1_700_000_000 + 86400 * 60), paceMinPerKm: 5.0, startOffsetFrac: 0.0, jitter: 5.0, seed: &s)
        if var last = tooLong.last {
            let extra: [(Double, Double)] = [(last.lat + 0.0005, last.lon + 0.0005), (last.lat + 0.0010, last.lon + 0.0010), (last.lat + 0.0015, last.lon + 0.0015)]
            let startT = last.t
            for (i, p) in extra.enumerated() {
                tooLong.append(GPSSample(id: UUID(), t: startT.addingTimeInterval(Double(i+1) * 6.0), lat: p.0, lon: p.1, alt: nil, hAcc: 8.0, speed: 2.0))
            }
        }
        let tooLongDist = loopDist * 1.4
        let tooLongRecord = WorkoutRecord(id: UUID(), sourceWorkoutUUID: "debug-too-long", activityType: .run, startDate: tooLong.first?.t ?? Date(), endDate: tooLong.last?.t ?? Date(), durationSeconds: tooLong.last?.t.timeIntervalSince(tooLong.first?.t ?? Date()) ?? 0, distanceMeters: tooLongDist, samples: tooLong, hasRoute: true, pauseIntervals: [])

        // Pause test.
        let pauseBase = Date(timeIntervalSince1970: 1_700_000_000 + 86400 * 70)
        let pauseSamples = makeSamples(points: loopPoints, base: pauseBase, paceMinPerKm: 4.8, startOffsetFrac: 0.0, jitter: 5.0, seed: &s)
        let pause = WorkoutRecord(id: UUID(), sourceWorkoutUUID: "debug-pause", activityType: .run, startDate: pauseBase, endDate: pauseBase.addingTimeInterval(2400), durationSeconds: 2400, distanceMeters: loopDist, samples: pauseSamples, hasRoute: true, pauseIntervals: [PauseInterval(start: pauseBase.addingTimeInterval(600), end: pauseBase.addingTimeInterval(720))])

        return DebugFixtureSet(loopWorkouts: loopWorkouts, pointToPoint: pt, reverseWorkout: rev, noRoute: noRoute, dropout: dropout, tooLong: tooLongRecord, pauseWorkout: pause, canonicalLoopPoints: loopPoints, canonicalLoopDist: loopDist)
    }

    private static func makeSamples(points: [(lat: Double, lon: Double)], base: Date, paceMinPerKm: Double, startOffsetFrac: Double, jitter: Double, seed: inout UInt64) -> [GPSSample] {
        let totalTime = (paceMinPerKm / 60.0) * (SeededRouteGenerator.length(points: points) / 1000.0)
        let n = max(1, Int(totalTime / 5.0))
        let startIdx = max(0, min(points.count - 1, Int(Double(points.count) * max(0, startOffsetFrac))))
        var samples: [GPSSample] = []
        for i in 0..<n {
            let t = base.addingTimeInterval(Double(i) * 5.0)
            let idx = min(points.count - 1, Int(Double(i) / Double(n) * Double(points.count - startIdx)) + startIdx).clamped(to: startIdx..<points.count)
            let p = points[idx]
            let jLat = SeededRNG.next(in: -jitter * 0.00001...jitter * 0.00001, seed: &seed)
            let jLon = SeededRNG.next(in: -jitter * 0.00001...jitter * 0.00001, seed: &seed)
            let spd = (1000.0 / (paceMinPerKm * 60.0)) + SeededRNG.next(in: -0.5...0.5, seed: &seed)
            samples.append(GPSSample(id: UUID(), t: t, lat: p.lat + jLat, lon: p.lon + jLon, alt: nil, hAcc: SeededRNG.next(in: 4.0...12.0, seed: &seed), speed: max(0, spd)))
        }
        return samples
    }
}

struct DebugFixtureSet {
    let loopWorkouts: [WorkoutRecord]
    let pointToPoint: WorkoutRecord
    let reverseWorkout: WorkoutRecord
    let noRoute: WorkoutRecord
    let dropout: WorkoutRecord
    let tooLong: WorkoutRecord
    let pauseWorkout: WorkoutRecord
    let canonicalLoopPoints: [(lat: Double, lon: Double)]
    let canonicalLoopDist: Double
}

// MARK: - DebugWorkoutSource

final class DebugWorkoutSource: WorkoutSource, Sendable {
    private let fixtureSet: DebugFixtureSet
    private var imported = false

    init(seed: UInt64 = 12345) { self.fixtureSet = DebugFixtureGenerator.generate(seed: seed) }

    var isHealthKitAvailable: Bool { true }

    func requestAccess() async -> HealthKitAccessResult { .authorised }

    func importAll() -> WorkoutImportStream {
        WorkoutImportStreamImpl {
            guard !self.imported else { return nil }
            self.imported = true
            let all = allWorkouts
            let withGPS = all.filter { $0.hasGPS }.count
            return WorkoutImportStream.Element(phase: .finished(importedCount: all.count, withGPSCount: withGPS), importedCount: all.count, withGPSCount: withGPS)
        }
    }

    func importSince(startDate: Date?) async -> WorkoutImportResult {
        let all = allWorkouts
        return WorkoutImportResult(importedCount: all.count, withGPSCount: all.filter { $0.hasGPS }.count, latestStartDate: all.map(\.startDate).max(), error: nil)
    }

    private var allWorkouts: [WorkoutRecord] {
        var list = fixtureSet.loopWorkouts
        list.append(contentsOf: [fixtureSet.pointToPoint, fixtureSet.reverseWorkout, fixtureSet.noRoute, fixtureSet.dropout, fixtureSet.tooLong, fixtureSet.pauseWorkout])
        return list
    }
}

extension DebugWorkoutSource {
    var asWorkouts: [WorkoutRecord] { allWorkouts }
}

#endif
