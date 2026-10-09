import Foundation
import SwiftData

actor GeminiService {
    static let shared = GeminiService()
    static let defaultModelID = "gemini-3.5-flash-lite"

    private let session: URLSession
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    func debrief(for workout: Workout, modelContext: ModelContext) async {
        let existing = try? modelContext.fetch(FetchDescriptor<RaceEngineerDebrief>(predicate: #Predicate { $0.workouUUID == workout.sourceWorkoutUUID })).first
        if existing != nil { return }

        guard let key = KeychainService.shared.geminiKey, !key.isEmpty else { return }
        let modelID = KeychainService.shared.geminiModelID ?? Self.defaultModelID
        let payload = buildPayload(for: workout, modelContext: modelContext)
        let result = await fetchDebrief(payload: payload, key: key, modelID: modelID)
        if case .ok(let data) = result {
            let debrief = RaceEngineerDebrief(workouUUID: workout.sourceWorkoutUUID, modelID: modelID, promptVersion: 1, payloadVersion: 1, content: data)
            modelContext.insert(debrief)
            try? modelContext.save()
        }
    }

    func validateKey(key: String?, modelID: String) async -> ValidateResult {
        guard let key, !key.isEmpty else { return .noKey }
        let payload = GeminiPayload(circuitName: "test", activityType: "run", date: "2026-01-01", lapTime: "01:00.00", sectorTimes: "S1: 00:20.00, S2: 00:20.00, S3: 00:20.00", deltasToBest: [], deltasToPrevious: [], recentLaps: [])
        let result = await fetchDebrief(payload: payload, key: key, modelID: modelID)
        switch result {
        case .ok: return .ok
        case .error(let msg):
            if msg.contains("401") || msg.contains("403") { return .invalidKey }
            if msg.lowercased().contains("model") { return .modelNotFound }
            if msg.contains("429") { return .rateLimited }
            return .networkError(msg)
        }
    }

    // MARK: - Network

    private enum FetchResult { case ok(Data); case error(String) }

    private func fetchDebrief(payload: GeminiPayload, key: String, modelID: String) async -> FetchResult {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent") else {
            return .error("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try? encoder.encode(GeminiRequest(payload: payload, modelID: modelID))

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .error("Network error") }
            switch http.statusCode {
            case 200: return .ok(data)
            case 401, 403: return .error("401/403: invalid API key")
            case 429: return .error("429: rate limited")
            default: return .error("HTTP \(http.statusCode)")
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Payload building

    private func buildPayload(for workout: Workout, modelContext: ModelContext) -> GeminiPayload {
        var lapPhrase = "—"
        if let lt = workout.lapTimeSeconds { lapPhrase = TimeFormat.absolute(lt) }

        var sectorPhrases: [String] = []
        if let circuit = workout.circuit {
            for idx in 1...3 {
                let desc = FetchDescriptor<SectorResult>(predicate: #Predicate { r in r.workouUUID == workout.sourceWorkoutUUID && r.sectorIndex == idx })
                if let r = (try? modelContext.fetch(desc)).flatMap({ $0.first }) {
                    sectorPhrases.append("S\(idx): \(r.durationSeconds.map(TimeFormat.absolute) ?? "—")")
                } else {
                    sectorPhrases.append("S\(idx): —")
                }
            }
        }

        let recentLaps = recentLapsPayload(for: workout, modelContext: modelContext)
        let deltasBest = deltasToBestPayload(for: workout, modelContext: modelContext)
        let deltasPrev = deltasToPreviousPayload(for: workout, modelContext: modelContext)

        return GeminiPayload(
            circuitName: workout.circuit?.name ?? "—",
            activityType: workout.activityType.displayName,
            date: workout.startDate.formatted(.dateTime.day().month().year()),
            lapTime: lapPhrase,
            sectorTimes: sectorPhrases.joined(separator: ", "),
            deltasToBest: deltasBest,
            deltasToPrevious: deltasPrev,
            recentLaps: recentLaps
        )
    }

    private func recentLapsPayload(for workout: Workout, modelContext: ModelContext) -> [String] {
        guard let circuit = workout.circuit else { return [] }
        let desc = FetchDescriptor<Workout>(predicate: #Predicate { w in w.circuit?.id == circuit.id && w.timingStatus == .valid && w.startDate < workout.startDate }, sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        let laps = (try? modelContext.fetch(desc)) ?? []
        return Array(laps.prefix(5)).map { w in
            let lt = w.lapTimeSeconds.map(TimeFormat.absolute) ?? "—"
            return "\(w.startDate.formatted(.dateTime.day().month())) \(lt)"
        }
    }

    private func deltasToBestPayload(for workout: Workout, modelContext: ModelContext) -> [String] {
        guard let circuit = workout.circuit else { return [] }
        var deltas: [String] = []
        if let best = Circuit.bestLapTime(for: circuit, modelContext: modelContext), let lt = workout.lapTimeSeconds {
            deltas.append("Best lap delta: \(TimeFormat.delta(lt - best))")
        }
        for idx in 1...3 {
            if let best = bestSectorTime(for: circuit, idx: idx, modelContext: modelContext) {
                let desc = FetchDescriptor<SectorResult>(predicate: #Predicate { r in r.workouUUID == workout.sourceWorkoutUUID && r.sectorIndex == idx })
                if let r = (try? modelContext.fetch(desc)).flatMap({ $0.first }), let dur = r.durationSeconds {
                    deltas.append("S\(idx) best delta: \(TimeFormat.delta(dur - best))")
                }
            }
        }
        return deltas
    }

    private func deltasToPreviousPayload(for workout: Workout, modelContext: ModelContext) -> [String] {
        guard let circuit = workout.circuit else { return [] }
        let desc = FetchDescriptor<Workout>(predicate: #Predicate { w in w.circuit?.id == circuit.id && w.timingStatus == .valid && w.startDate < workout.startDate }, sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        let prevLaps = (try? modelContext.fetch(desc)) ?? []
        guard let prev = prevLaps.first else { return [] }
        var deltas: [String] = []
        if let prevLap = prev.lapTimeSeconds, let lt = workout.lapTimeSeconds {
            deltas.append("Previous lap delta: \(TimeFormat.delta(lt - prevLap))")
        }
        for idx in 1...3 {
            let prevDesc = FetchDescriptor<SectorResult>(predicate: #Predicate { r in r.workouUUID == prev.sourceWorkoutUUID && r.sectorIndex == idx })
            let curDesc = FetchDescriptor<SectorResult>(predicate: #Predicate { r in r.workouUUID == workout.sourceWorkoutUUID && r.sectorIndex == idx })
            if let cur = (try? modelContext.fetch(curDesc)).flatMap({ $0.first }), let p = (try? modelContext.fetch(prevDesc)).flatMap({ $0.first }), let cd = cur.durationSeconds, let pd = p.durationSeconds {
                deltas.append("S\(idx) prev delta: \(TimeFormat.delta(cd - pd))")
            }
        }
        return deltas
    }

    private func bestSectorTime(for circuit: Circuit, idx: Int, modelContext: ModelContext) -> Double? {
        let laps = Workout.fetchValidLaps(for: circuit, modelContext: modelContext)
        var best: Double?
        for w in laps {
            let desc = FetchDescriptor<SectorResult>(predicate: #Predicate { r in r.workouUUID == w.sourceWorkoutUUID && r.sectorIndex == idx })
            if let r = (try? modelContext.fetch(desc)).flatMap({ $0.first }), let d = r.durationSeconds {
                if best == nil || d < best! { best = d }
            }
        }
        return best
    }

    // MARK: - Validation enum

    enum ValidateResult: Sendable {
        case ok, invalidKey, modelNotFound, rateLimited, networkError(String), noKey
    }
}

// MARK: - Payload / request / response

struct GeminiPayload: Codable {
    let circuitName: String
    let activityType: String
    let date: String
    let lapTime: String
    let sectorTimes: String
    let deltasToBest: [String]
    let deltasToPrevious: [String]
    let recentLaps: [String]
}

struct GeminiRequest: Codable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
    let modelID: String

    struct GeminiContent: Codable { let parts: [GeminiPart] }
    struct GeminiPart: Codable { let text: String }
    struct GeminiGenerationConfig: Codable {
        let responseMimeType: String
        let responseJsonSchema: GeminiJsonSchema?
    }
    struct GeminiJsonSchema: Codable { let schema: GeminiSchema }
    struct GeminiSchema: Codable { let type: String; let description: String?; let fields: [GeminiField] }
    struct GeminiField: Codable { let key: String; let value: GeminiValue }
    struct GeminiValue: Codable {
        let type: String; let description: String?; let fields: [GeminiField]?; let items: GeminiValue?; let format: String?
    }
}

struct DebriefPayload: Sendable {
    let headline: String
    let summary: String
    let sectorNotes: [DebriefSectorNote]
    let hypotheses: [String]?
    let focusNext: [String]?
    let contentJSON: Data

    struct DebriefSectorNote: Sendable { let sector: Int; let note: String }

    init?(json: Data) {
        guard let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let headline = dict["headline"] as? String,
              let summary = dict["summary"] as? String else { return nil }
        self.headline = headline
        self.summary = summary
        self.contentJSON = json
        self.sectorNotes = (dict["sectorNotes"] as? [[String: Any]])?.compactMap { item in
            guard let s = item["sector"] as? Int, let n = item["note"] as? String else { return nil }
            return DebriefSectorNote(sector: s, note: n)
        } ?? []
        self.hypotheses = (dict["hypotheses"] as? [String]) ?? nil
        self.focusNext = (dict["focusNext"] as? [String]) ?? nil
    }
}
