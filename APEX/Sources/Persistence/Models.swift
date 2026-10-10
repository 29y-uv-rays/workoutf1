import SwiftData
import Foundation

// MARK: - Workout

@Model
final class Workout {
    @Attribute(.unique) var sourceWorkoutUUID: String
    var activityTypeRaw: String
    var startDate: Date
    var endDate: Date
    var durationSeconds: Double
    var distanceMeters: Double
    var routeFile: String?
    var timingStatusRaw: String
    var lapTimeSeconds: Double?
    var lapColourRaw: String?
    var circuitVersion: Int
    var algorithmVersion: Int
    var circuit: Circuit?

    var activityType: ActivityType {
        get { ActivityType(rawValue: activityTypeRaw) ?? .run }
        set { activityTypeRaw = newValue.rawValue }
    }

    var timingStatus: TimingStatus {
        get { TimingStatus(rawValue: timingStatusRaw) ?? .pending }
        set { timingStatusRaw = newValue.rawValue }
    }

    var lapColour: SectorColor? {
        get { SectorColor(rawValue: lapColourRaw ?? "") }
        set { lapColourRaw = newValue?.rawValue }
    }

    init(sourceWorkoutUUID: String, activityType: ActivityType, startDate: Date, endDate: Date, durationSeconds: Double, distanceMeters: Double, routeFile: String? = nil, timingStatus: TimingStatus = .pending, lapTimeSeconds: Double? = nil, lapColour: SectorColor? = nil, circuitVersion: Int = 0, algorithmVersion: Int = TimingEngine.algorithmVersion, circuit: Circuit? = nil) {
        self.sourceWorkoutUUID = sourceWorkoutUUID
        self.activityTypeRaw = activityType.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.routeFile = routeFile
        self.timingStatusRaw = timingStatus.rawValue
        self.lapTimeSeconds = lapTimeSeconds
        self.lapColourRaw = lapColour?.rawValue
        self.circuitVersion = circuitVersion
        self.algorithmVersion = algorithmVersion
        self.circuit = circuit
    }
}

// MARK: - Circuit

@Model
final class Circuit {
    @Attribute(.unique) var id: UUID
    var name: String
    var activityTypeRaw: String
    var geometryFile: String
    var totalDistanceMeters: Double
    var isLoop: Bool
    var originWorkoutUUID: String
    var version: Int
    var createdAt: Date
    var sectors: [SectorDefinition]

    var activityType: ActivityType {
        get { ActivityType(rawValue: activityTypeRaw) ?? .run }
        set { activityTypeRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), name: String, activityType: ActivityType, geometryFile: String, totalDistanceMeters: Double, isLoop: Bool = false, originWorkoutUUID: String, sectors: [SectorDefinition]? = nil, version: Int = 1, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.activityTypeRaw = activityType.rawValue
        self.geometryFile = geometryFile
        self.totalDistanceMeters = totalDistanceMeters
        self.isLoop = isLoop
        self.originWorkoutUUID = originWorkoutUUID
        self.version = version
        self.createdAt = createdAt
        self.sectors = sectors ?? Self.defaultSectors(for: totalDistanceMeters)
    }

    private static func defaultSectors(for total: Double) -> [SectorDefinition] {
        let third = total / 3.0
        return [
            SectorDefinition(index: 1, startDistanceMeters: 0, endDistanceMeters: third),
            SectorDefinition(index: 2, startDistanceMeters: third, endDistanceMeters: 2 * third),
            SectorDefinition(index: 3, startDistanceMeters: 2 * third, endDistanceMeters: total),
        ]
    }

    func sectorDefinition(at index: Int) -> SectorDefinition? { sectors.first { $0.index == index } }
    func boundaryCoordinate(at fraction: Double, points: [MapPoint]) -> CLLocationCoordinate2D {
        guard !points.isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        let target = totalDistanceMeters * max(0, min(1, fraction))
        for (i, p) in points.enumerated() {
            let d = Double(i) / Double(max(1, points.count - 1)) * totalDistanceMeters
            if d >= target { return CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }
        }
        return CLLocationCoordinate2D(latitude: points.last!.lat, longitude: points.last!.lon)
    }
}

// MARK: - SectorDefinition

@Model
final class SectorDefinition {
    var index: Int
    var startDistanceMeters: Double
    var endDistanceMeters: Double
    var circuit: Circuit?

    init(index: Int, startDistanceMeters: Double, endDistanceMeters: Double) {
        self.index = index; self.startDistanceMeters = startDistanceMeters; self.endDistanceMeters = endDistanceMeters
    }
}

// MARK: - SectorResult

@Model
final class SectorResult {
    @Attribute(.unique) var id: UUID
    var sectorIndex: Int
    var durationSeconds: Double?
    var colourRaw: String?
    var workouUUID: String
    var circuitVersion: Int
    var algorithmVersion: Int
    var createdAt: Date

    var colour: SectorColor? {
        get { SectorColor(rawValue: colourRaw ?? "") }
        set { colourRaw = newValue?.rawValue }
    }

    init(id: UUID = UUID(), sectorIndex: Int, durationSeconds: Double?, colour: SectorColor?, workouUUID: String, circuitVersion: Int, algorithmVersion: Int, createdAt: Date = Date()) {
        self.id = id; self.sectorIndex = sectorIndex; self.durationSeconds = durationSeconds
        self.colourRaw = colour?.rawValue; self.workouUUID = workouUUID
        self.circuitVersion = circuitVersion; self.algorithmVersion = algorithmVersion; self.createdAt = createdAt
    }
}

// MARK: - RaceEngineerDebrief

@Model
final class RaceEngineerDebrief {
    @Attribute(.unique) var id: UUID
    var workouUUID: String
    var modelID: String
    var promptVersion: Int
    var payloadVersion: Int
    var contentJSON: Data
    var createdAt: Date

    init(id: UUID = UUID(), workouUUID: String, modelID: String, promptVersion: Int, payloadVersion: Int, content: Data, createdAt: Date = Date()) {
        self.id = id; self.workouUUID = workouUUID; self.modelID = modelID
        self.promptVersion = promptVersion; self.payloadVersion = payloadVersion; self.contentJSON = content; self.createdAt = createdAt
    }

    func payload() -> DebriefPayload? { DebriefPayload(json: contentJSON) }
}

// MARK: - TimingStatus

enum TimingStatus: String, Codable, Sendable, CaseIterable {
    case pending, valid, partial, missingGPS, unmatched, needsCircuitChoice
}

// MARK: - MapPoint

struct MapPoint: Codable, Sendable, Identifiable {
    let id: UUID
    let lat: Double
    let lon: Double
}

extension CLLocationCoordinate2D: @retroactive Identifiable {
    public var id: String { "\(latitude),\(longitude)" }
}

// MARK: - Fetches

extension Workout {
    static func fetchValidLaps(for circuit: Circuit, modelContext: ModelContext) -> [Workout] {
        let circuitID = circuit.id
        let version = circuit.version
        let algorithm = TimingEngine.algorithmVersion
        let valid = TimingStatus.valid.rawValue
        let desc = FetchDescriptor<Workout>(predicate: #Predicate { w in w.circuit?.id == circuitID && w.timingStatusRaw == valid && w.circuitVersion == version && w.algorithmVersion == algorithm }, sortBy: [SortDescriptor(\.startDate)])
        return (try? modelContext.fetch(desc)) ?? []
    }

    static func fetchAllLapsSorted(modelContext: ModelContext) -> [Workout] {
        let desc = FetchDescriptor<Workout>(predicate: #Predicate { _ in true }, sortBy: [SortDescriptor(\.startDate)])
        return (try? modelContext.fetch(desc)) ?? []
    }
}

extension Circuit {
    static func fetchAll(modelContext: ModelContext) -> [Circuit] {
        let desc = FetchDescriptor<Circuit>(sortBy: [SortDescriptor(\.name)])
        return (try? modelContext.fetch(desc)) ?? []
    }

    static func bestLapTime(for circuit: Circuit, modelContext: ModelContext) -> Double? {
        let laps = Workout.fetchValidLaps(for: circuit, modelContext: modelContext)
        return laps.compactMap(\.lapTimeSeconds).min()
    }
}

extension Workout {
    var modelContext: ModelContext? { nil }
}
