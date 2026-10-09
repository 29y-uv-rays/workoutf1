import Foundation

struct RouteFile: Codable, Sendable {
    let samples: [RouteSample]
    let writtenAt: Date

    struct RouteSample: Codable, Sendable {
        let lat: Double; let lon: Double; let alt: Double?; let hAcc: Double?; let speed: Double?; let t: Date
    }

    init(samples: [GPSSample], writtenAt: Date = Date()) {
        self.samples = samples.map { RouteSample(lat: $0.lat, lon: $0.lon, alt: $0.alt, hAcc: $0.hAcc, speed: $0.speed, t: $0.t) }
        self.writtenAt = writtenAt
    }

    func toGPSSamples() -> [GPSSample] { samples.map { GPSSample(t: $0.t, lat: $0.lat, lon: $0.lon, alt: $0.alt, hAcc: $0.hAcc, speed: $0.speed) } }
}

struct CircuitPolylineFile: Codable, Sendable {
    let points: [CircuitPoint]
    let distanceMeters: Double
    let activityType: String
    let isLoop: Bool
    let writtenAt: Date

    struct CircuitPoint: Codable, Sendable { let lat: Double; let lon: Double; let cumulative: Double }
}

final class FileStore: Sendable {
    private let routesDir: URL
    private let circuitsDir: URL
    private let fileManager = FileManager.default

    init() {
        let base = applicationSupportURL().appendingPathComponent("APEX", isDirectory: true)
        self.routesDir = base.appendingPathComponent("routes", isDirectory: true)
        self.circuitsDir = base.appendingPathComponent("circuits", isDirectory: true)
        try? createDirectories()
    }

    private func applicationSupportURL() -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    private func createDirectories() throws {
        try fileManager.createDirectory(at: routesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: circuitsDir, withIntermediateDirectories: true)
    }

    // MARK: - Route files

    func writeRouteJSON(_ samples: [GPSSample]) -> String? {
        let file = RouteFile(samples: samples)
        let fileName = "route-\(samples.first?.id.uuidString ?? UUID().uuidString).json"
        let url = routesDir.appendingPathComponent(fileName)
        do {
            try JSONEncoder().encode(file).write(to: url)
            return fileName
        } catch { return nil }
    }

    func loadRouteJSON(for id: String) -> [MapPoint]? {
        let url = routesDir.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let file = try JSONDecoder().decode(RouteFile.self, from: try Data(contentsOf: url))
            return file.samples.map { MapPoint(id: UUID(), lat: $0.lat, lon: $0.lon) }
        } catch { return nil }
    }

    func loadRouteSamples(for id: String) -> [GPSSample]? {
        let url = routesDir.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(RouteFile.self, from: try Data(contentsOf: url)).toGPSSamples()
        } catch { return nil }
    }

    // MARK: - Circuit polyline files

    func writeCircuitPolyline(_ points: [(lat: Double, lon: Double)], distanceMeters: Double, activityType: ActivityType, isLoop: Bool) -> String? {
        var cum: Double = 0
        var cumulativePoints: [CircuitPoint] = []
        for (i, p) in points.enumerated() {
            cumulativePoints.append(CircuitPoint(lat: p.lat, lon: p.lon, cumulative: i == 0 ? 0 : cum))
            if i > 0 {
                cum += localDistance(lat1: points[i-1].lat, lon1: points[i-1].lon, lat2: p.lat, lon2: p.lon)
            }
        }
        let file = CircuitPolylineFile(points: cumulativePoints, distanceMeters: cum, activityType: activityType.rawValue, isLoop: isLoop, writtenAt: Date())
        let fileName = "circuit-\(UUID().uuidString).json"
        let url = circuitsDir.appendingPathComponent(fileName)
        do {
            try JSONEncoder().encode(file).write(to: url)
            return fileName
        } catch { return nil }
    }

    func loadCircuitPolylinePoints(for fileName: String) -> [(lat: Double, lon: Double)]? {
        let url = circuitsDir.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let file = try JSONDecoder().decode(CircuitPolylineFile.self, from: try Data(contentsOf: url))
            return file.points.map { (lat: $0.lat, lon: $0.lon) }
        } catch { return nil }
    }

    // MARK: - Delete

    func deleteAllFiles() throws {
        try deleteContents(of: routesDir)
        try deleteContents(of: circuitsDir)
    }

    private func deleteContents(of url: URL) throws {
        for item in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: item)
        }
    }

    func deleteRouteFile(for id: String) throws {
        try fileManager.removeItem(at: routesDir.appendingPathComponent("\(id).json"))
    }

    func deleteCircuitFile(for id: UUID) throws {
        try fileManager.removeItem(at: circuitsDir.appendingPathComponent("\(id.uuidString).json"))
    }

    // MARK: - Geometry helpers

    private func localDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371000.0
        let x = (lon2 - lon1) * .pi / 180.0 * cos((lat1 + lat2) / 2 * .pi / 180.0) * r
        let y = (lat2 - lat1) * .pi / 180.0 * r
        return hypot(x, y)
    }
}
