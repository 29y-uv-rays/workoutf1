import Foundation
import SwiftData

actor RecomputeService {
    private let container: ModelContainer
    private let fileStore: FileStore

    init(container: ModelContainer, fileStore: FileStore) {
        self.container = container
        self.fileStore = fileStore
    }

    func recomputeAll() async {
        let ctx = container.mainContext
        // Ascending by date: each lap can then use earlier laps on the same circuit as its
        // route-record / previous-lap reference when colours are assigned.
        let workouts = Workout.fetchAllLapsSorted(modelContext: ctx)
        var anyChange = false
        var lapTimes: [String: Double] = [:]
        var sectorTimes: [String: [Int: Double]] = [:]

        for w in workouts {
            guard w.routeFile != nil else {
                if w.distanceMeters == 0, w.timingStatus != .missingGPS {
                    w.timingStatus = .missingGPS
                    anyChange = true
                }
                continue
            }
            guard let circuit = w.circuit else {
                if w.timingStatus != .unmatched { w.timingStatus = .unmatched; anyChange = true }
                continue
            }
            guard w.circuitVersion == circuit.version else { continue }

            let samples = fileStore.loadRouteSamples(for: w.sourceWorkoutUUID) ?? []
            guard !samples.isEmpty else {
                if w.timingStatus != .missingGPS { w.timingStatus = .missingGPS; anyChange = true }
                continue
            }
            guard let polyline = polyline(for: circuit) else {
                if w.timingStatus != .unmatched { w.timingStatus = .unmatched; anyChange = true }
                continue
            }

            let engine = TimingEngine()
            let input = WorkoutForEngine(
                sourceWorkoutUUID: w.sourceWorkoutUUID,
                activityType: w.activityType,
                startDate: w.startDate,
                endDate: w.endDate,
                durationSeconds: w.durationSeconds,
                distanceMeters: w.distanceMeters,
                samples: samples,
                hasRoute: true,
                pauseIntervals: [],  // pause intervals are not persisted in the model yet; zero for M0
                circuit: CircuitForEngine(circuit: circuit, polyline: polyline),
                circuitVersion: circuit.version,
                algorithmVersion: TimingEngine.algorithmVersion
            )

            let analysis = engine.analyse(input)

            // Earlier laps on this circuit (same version) that already have a time this pass.
            let priorUUIDs = workouts.compactMap { p -> String? in
                guard p.sourceWorkoutUUID != w.sourceWorkoutUUID,
                      p.circuit?.id == circuit.id,
                      p.circuitVersion == circuit.version,
                      lapTimes[p.sourceWorkoutUUID] != nil else { return nil }
                return p.sourceWorkoutUUID
            }
            let previousLap = priorUUIDs.last.flatMap { lapTimes[$0] }
            let bestLap = priorUUIDs.compactMap { lapTimes[$0] }.min()

            if let lapTime = analysis.lapTime {
                w.lapTimeSeconds = lapTime
                w.lapColour = Self.lapColour(lapTime: lapTime, best: bestLap, previous: previousLap)
                w.timingStatus = analysis.isValid && analysis.sectorResults.allSatisfy({ $0.duration != nil }) ? .valid : .partial
            } else {
                w.lapTimeSeconds = nil
                w.lapColour = nil
                w.timingStatus = .unmatched
            }
            w.circuitVersion = circuit.version
            w.algorithmVersion = TimingEngine.algorithmVersion

            // F1-style sector colours: purple = new record, green = faster than your previous lap,
            // yellow = slower, grey = no valid time.
            clearSectorResults(for: w.sourceWorkoutUUID, modelContext: ctx)
            var durationsForWorkout: [Int: Double] = [:]
            for (position, sr) in analysis.sectorResults.enumerated() {
                let sectorIndex = position + 1
                let duration = sr.duration
                let colour = Self.sectorColour(
                    duration: duration,
                    best: priorUUIDs.compactMap { sectorTimes[$0]?[sectorIndex] }.min(),
                    previous: priorUUIDs.last.flatMap { sectorTimes[$0]?[sectorIndex] }
                )
                let row = SectorResult(
                    sectorIndex: sectorIndex,
                    durationSeconds: duration,
                    colour: colour,
                    workouUUID: w.sourceWorkoutUUID,
                    circuitVersion: circuit.version,
                    algorithmVersion: TimingEngine.algorithmVersion
                )
                ctx.insert(row)
                if let duration { durationsForWorkout[sectorIndex] = duration }
            }
            lapTimes[w.sourceWorkoutUUID] = analysis.lapTime
            sectorTimes[w.sourceWorkoutUUID] = durationsForWorkout
            anyChange = true
        }

        if anyChange { try? ctx.save() }
    }

    func reanalyseAll() async { await recomputeAll() }

    // MARK: - References

    private func polyline(for circuit: Circuit) -> [(lat: Double, lon: Double)]? {
        if let points = fileStore.loadCircuitPolylinePoints(for: circuit.geometryFile), points.count >= 2 { return points }
        if let samples = fileStore.loadRouteSamples(for: circuit.originWorkoutUUID), samples.count >= 2 {
            return samples.map { ($0.lat, $0.lon) }
        }
        return nil
    }

    private static func sectorColour(duration: Double?, best: Double?, previous: Double?) -> SectorColor {
        guard let duration else { return .grey }
        if let best, duration < best - 0.005 { return .purple }
        guard let previous else { return .purple } // first recorded time for this sector
        return duration < previous - 0.005 ? .green : .yellow
    }

    private static func lapColour(lapTime: Double, best: Double?, previous: Double?) -> SectorColor {
        if let best, lapTime < best - 0.005 { return .purple }
        guard let previous else { return .purple }
        return lapTime < previous - 0.005 ? .green : .yellow
    }

    private func clearSectorResults(for uuid: String, modelContext: ModelContext) {
        let desc = FetchDescriptor<SectorResult>(predicate: #Predicate { $0.workouUUID == uuid })
        if let existing = try? modelContext.fetch(desc) {
            for s in existing { modelContext.delete(s) }
        }
    }
}

// MARK: - Engine input/output bridge

struct WorkoutForEngine {
    let sourceWorkoutUUID: String
    let activityType: ActivityType
    let startDate: Date
    let endDate: Date
    let durationSeconds: Double
    let distanceMeters: Double
    let samples: [GPSSample]
    let hasRoute: Bool
    let pauseIntervals: [PauseInterval]
    let circuit: CircuitForEngine
    let circuitVersion: Int
    let algorithmVersion: Int
}

struct CircuitForEngine {
    let id: UUID
    let name: String
    let activityType: ActivityType
    let totalDistanceMeters: Double
    let isLoop: Bool
    let version: Int
    let sectors: [SectorDefForEngine]
    let polyline: [(lat: Double, lon: Double)]

    init(id: UUID, name: String, activityType: ActivityType, totalDistanceMeters: Double, isLoop: Bool, version: Int, sectors: [SectorDefForEngine], polyline: [(lat: Double, lon: Double)]) {
        self.id = id
        self.name = name
        self.activityType = activityType
        self.totalDistanceMeters = totalDistanceMeters
        self.isLoop = isLoop
        self.version = version
        self.sectors = sectors
        self.polyline = polyline
    }

    init(circuit: Circuit, polyline: [(lat: Double, lon: Double)]) {
        self.id = circuit.id
        self.name = circuit.name
        self.activityType = circuit.activityType
        self.totalDistanceMeters = circuit.totalDistanceMeters
        self.isLoop = circuit.isLoop
        self.version = circuit.version
        self.sectors = circuit.sectors
            .sorted { $0.index < $1.index }
            .map { SectorDefForEngine(index: $0.index, startDistanceMeters: $0.startDistanceMeters, endDistanceMeters: $0.endDistanceMeters) }
        self.polyline = polyline
    }
}

struct SectorDefForEngine {
    let index: Int
    let startDistanceMeters: Double
    let endDistanceMeters: Double
}

struct LapAnalysisResult {
    let lapTime: Double?
    let lapColour: SectorColor?
    let sectorResults: [SectorResultForEngine]
    let isValid: Bool
    let reason: String?
    let matchScore: Double

    struct SectorResultForEngine {
        let duration: Double?
        let colour: SectorColor?
    }
}
