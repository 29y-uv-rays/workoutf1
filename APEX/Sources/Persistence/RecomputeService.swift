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
        let workouts = Workout.fetchAllLapsSorted(modelContext: ctx)
        var anyChange = false

        for w in workouts {
            guard w.routeFile != nil else {
                if w.distanceMeters == 0 { w.timingStatus = .missingGPS }
                continue
            }
            guard w.circuit != nil else { w.timingStatus = .unmatched; continue }
            guard let circuit = w.circuit else { continue }
            guard w.circuitVersion == circuit.version else { continue }

            let samples = fileStore.loadRouteSamples(for: w.sourceWorkoutUUID) ?? []
            guard !samples.isEmpty else { w.timingStatus = .missingGPS; continue }

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
                circuit: CircuitForEngine(circuit: circuit),
                circuitVersion: circuit.version,
                algorithmVersion: TimingEngine.algorithmVersion
            )

            let result = engine.analyse(input)

            w.timingStatus = result.lapTime != nil && result.sectorResults.allSatisfy({ $0.duration != nil }) ? .valid : .partial
            w.lapTimeSeconds = result.lapTime
            // colours set by caller after reference lookup
            w.circuitVersion = circuit.version
            w.algorithmVersion = TimingEngine.algorithmVersion

            clearSectorResults(for: w.sourceWorkoutUUID, modelContext: ctx)
            for (idx, sr) in result.sectorResults.enumerated() {
                let result = SectorResult(sectorIndex: idx + 1, durationSeconds: sr.duration, colour: nil, workouUUID: w.sourceWorkoutUUID, circuitVersion: circuit.version, algorithmVersion: TimingEngine.algorithmVersion)
                ctx.insert(result)
                result.workout = w
            }
            anyChange = true
        }

        if anyChange { try? ctx.save() }
    }

    func reanalyseAll() async { await recomputeAll() }

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

    init(circuit: Circuit) {
        self.id = circuit.id
        self.name = circuit.name
        self.activityType = circuit.activityType
        self.totalDistanceMeters = circuit.totalDistanceMeters
        self.isLoop = circuit.isLoop
        self.version = circuit.version
        self.sectors = circuit.sectors.map { SectorDefForEngine(index: $0.index, startDistanceMeters: $0.startDistanceMeters, endDistanceMeters: $0.endDistanceMeters) }
        // Polyline loaded from file in the caller; for engine we require it here.
        // If not available, the caller must supply it; here we load lazily in the service.
        self.polyline = []
    }

    init(id: UUID, name: String, activityType: ActivityType, totalDistanceMeters: Double, isLoop: Bool, version: Int, sectors: [SectorDefForEngine], polyline: [(lat: Double, lon: Double)]) {
        self.id = id; self.name = name; self.activityType = activityType
        self.totalDistanceMeters = totalDistanceMeters; self.isLoop = isLoop
        self.version = version; self.sectors = sectors; self.polyline = polyline
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
