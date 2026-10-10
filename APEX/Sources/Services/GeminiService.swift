import Foundation
import SwiftData

// MARK: - Fetch result

enum GeminiFetchResult: Sendable {
    case ok(Data)
    case error(String)
}

// MARK: - Gemini service

/// Networking only. Anything that touches SwiftData lives in `RaceEngineer` / `DebriefBuilder`
/// on the main actor, so a `ModelContext` never crosses an actor boundary.
actor GeminiService {
    static let shared = GeminiService()
    static let defaultModelID = "gemini-3.5-flash-lite"

    private let session: URLSession
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    func validateKey(key: String?, modelID: String) async -> GeminiFetchResultOutcome {
        guard let key, !key.isEmpty else { return .noKey }
        let payload = GeminiPayload(
            circuitName: "test",
            activityType: "run",
            date: "2026-01-01",
            lapTime: "01:00.00",
            sectorTimes: "S1: 00:20.00, S2: 00:20.00, S3: 00:20.00",
            deltasToBest: [],
            deltasToPrevious: [],
            recentLaps: []
        )
        let result = await requestDebrief(payload: payload, key: key, modelID: modelID)
        switch result {
        case .ok:
            return .ok
        case .error(let msg):
            if msg.contains("401") || msg.contains("403") { return .invalidKey }
            if msg.contains("404") || msg.lowercased().contains("model not") { return .modelNotFound }
            if msg.contains("429") { return .rateLimited }
            return .networkError(msg)
        }
    }

    /// Calls Gemini and returns the debrief JSON (the model's structured answer), not the raw
    /// transport envelope.
    func requestDebrief(payload: GeminiPayload, key: String, modelID: String) async -> GeminiFetchResult {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent") else {
            return .error("Invalid model ID — edit it in Settings.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try? encoder.encode(GeminiRequest(payload: payload))

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .error("Network error") }
            switch http.statusCode {
            case 200:
                guard let debrief = Self.extractDebrief(from: data) else {
                    return .error("Gemini returned an unexpected response shape.")
                }
                return .ok(debrief)
            case 401, 403: return .error("401/403: invalid API key")
            case 404: return .error("404: model not found — check Model ID in Settings.")
            case 429: return .error("429: rate limited")
            default: return .error("HTTP \(http.statusCode)")
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Gemini wraps the structured answer in a candidates envelope; pull the JSON text back out.
    private static func extractDebrief(from data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String,
              let json = text.data(using: .utf8) else { return nil }
        return json
    }
}

enum GeminiFetchResultOutcome: Sendable {
    case ok, invalidKey, modelNotFound, rateLimited, networkError(String), noKey
}

// MARK: - Race Engineer (main actor, owns SwiftData writes)

enum RaceEngineer {
    static func isCached(for workout: Workout, modelContext: ModelContext) -> Bool {
        let desc = FetchDescriptor<RaceEngineerDebrief>(predicate: #Predicate { $0.workouUUID == workout.sourceWorkoutUUID })
        return ((try? modelContext.fetch(desc)) ?? []).isEmpty == false
    }

    /// Fetches (or reuses the cached) debrief for a workout and stores it. Returns true when a
    /// debrief is available afterwards.
    @MainActor
    @discardableResult
    static func requestDebrief(for workout: Workout, modelContext: ModelContext) async -> Bool {
        if isCached(for: workout, modelContext: modelContext) { return true }
        guard let key = KeychainService.shared.geminiKey, !key.isEmpty else { return false }
        let modelID = KeychainService.shared.geminiModelID ?? GeminiService.defaultModelID
        let payload = DebriefBuilder.payload(for: workout, modelContext: modelContext)
        let result = await GeminiService.shared.requestDebrief(payload: payload, key: key, modelID: modelID)
        guard case .ok(let data) = result else { return false }
        modelContext.insert(RaceEngineerDebrief(
            workouUUID: workout.sourceWorkoutUUID,
            modelID: modelID,
            promptVersion: DebriefBuilder.promptVersion,
            payloadVersion: DebriefBuilder.payloadVersion,
            content: data
        ))
        try? modelContext.save()
        return true
    }
}

// MARK: - Payload building (main actor, reads SwiftData)

/// Builds the prompt payload. Only aggregated lap/sector numbers leave the device — never
/// coordinates or raw GPS.
enum DebriefBuilder {
    static let promptVersion = 1
    static let payloadVersion = 1

    static func payload(for workout: Workout, modelContext: ModelContext) -> GeminiPayload {
        var lapPhrase = "—"
        if let lt = workout.lapTimeSeconds { lapPhrase = TimeFormat.absolute(lt) }

        var sectorPhrases: [String] = []
        if workout.circuit != nil {
            for idx in 1...3 {
                if let r = sectorResult(for: workout, sectorIndex: idx, modelContext: modelContext) {
                    sectorPhrases.append("S\(idx): \(r.durationSeconds.map(TimeFormat.absolute) ?? "—")")
                } else {
                    sectorPhrases.append("S\(idx): —")
                }
            }
        }

        return GeminiPayload(
            circuitName: workout.circuit?.name ?? "—",
            activityType: workout.activityType.displayName,
            date: workout.startDate.formatted(.dateTime.day().month().year()),
            lapTime: lapPhrase,
            sectorTimes: sectorPhrases.joined(separator: ", "),
            deltasToBest: deltasToBest(workout, modelContext: modelContext),
            deltasToPrevious: deltasToPrevious(workout, modelContext: modelContext),
            recentLaps: recentLaps(workout, modelContext: modelContext)
        )
    }

    private static func sectorResult(for workout: Workout, sectorIndex: Int, modelContext: ModelContext) -> SectorResult? {
        let desc = FetchDescriptor<SectorResult>(predicate: #Predicate { r in r.workouUUID == workout.sourceWorkoutUUID && r.sectorIndex == sectorIndex })
        return ((try? modelContext.fetch(desc)) ?? []).first
    }

    private static func recentLaps(_ workout: Workout, modelContext: ModelContext) -> [String] {
        guard let circuit = workout.circuit else { return [] }
        let circuitID = circuit.id
        let desc = FetchDescriptor<Workout>(predicate: #Predicate { w in w.circuit?.id == circuitID && w.timingStatusRaw == TimingStatus.valid.rawValue && w.startDate < workout.startDate }, sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        let laps = (try? modelContext.fetch(desc)) ?? []
        return Array(laps.prefix(5)).map { w in
            let lt = w.lapTimeSeconds.map(TimeFormat.absolute) ?? "—"
            return "\(w.startDate.formatted(.dateTime.day().month())) \(lt)"
        }
    }

    private static func deltasToBest(_ workout: Workout, modelContext: ModelContext) -> [String] {
        guard let circuit = workout.circuit else { return [] }
        var deltas: [String] = []
        if let best = Circuit.bestLapTime(for: circuit, modelContext: modelContext), let lt = workout.lapTimeSeconds {
            deltas.append("Best lap delta: \(TimeFormat.delta(lt - best))")
        }
        for idx in 1...3 {
            guard let best = bestSectorTime(for: circuit, idx: idx, modelContext: modelContext) else { continue }
            if let r = sectorResult(for: workout, sectorIndex: idx, modelContext: modelContext), let dur = r.durationSeconds {
                deltas.append("S\(idx) best delta: \(TimeFormat.delta(dur - best))")
            }
        }
        return deltas
    }

    private static func deltasToPrevious(_ workout: Workout, modelContext: ModelContext) -> [String] {
        guard let circuit = workout.circuit else { return [] }
        let circuitID = circuit.id
        let desc = FetchDescriptor<Workout>(predicate: #Predicate { w in w.circuit?.id == circuitID && w.timingStatusRaw == TimingStatus.valid.rawValue && w.startDate < workout.startDate }, sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        let prevLaps = (try? modelContext.fetch(desc)) ?? []
        guard let prev = prevLaps.first else { return [] }
        var deltas: [String] = []
        if let prevLap = prev.lapTimeSeconds, let lt = workout.lapTimeSeconds {
            deltas.append("Previous lap delta: \(TimeFormat.delta(lt - prevLap))")
        }
        for idx in 1...3 {
            guard let cur = sectorResult(for: workout, sectorIndex: idx, modelContext: modelContext),
                  let p = sectorResult(for: prev, sectorIndex: idx, modelContext: modelContext),
                  let cd = cur.durationSeconds, let pd = p.durationSeconds else { continue }
            deltas.append("S\(idx) prev delta: \(TimeFormat.delta(cd - pd))")
        }
        return deltas
    }

    private static func bestSectorTime(for circuit: Circuit, idx: Int, modelContext: ModelContext) -> Double? {
        let laps = Workout.fetchValidLaps(for: circuit, modelContext: modelContext)
        var best: Double?
        for w in laps {
            if let r = sectorResult(for: w, sectorIndex: idx, modelContext: modelContext), let d = r.durationSeconds {
                if best == nil || d < best! { best = d }
            }
        }
        return best
    }
}

// MARK: - Prompt payload

struct GeminiPayload: Codable {
    let circuitName: String
    let activityType: String
    let date: String
    let lapTime: String
    let sectorTimes: String
    let deltasToBest: [String]
    let deltasToPrevious: [String]
    let recentLaps: [String]

    /// The prompt body — aggregated numbers only, no coordinates.
    var promptText: String {
        """
        You are the Race Engineer in APEX, a Formula 1-style lap timing app for runners and riders.
        Analyse this single lap and answer in JSON only.

        Circuit: \(circuitName)
        Activity: \(activityType)
        Date: \(date)
        Lap time: \(lapTime)
        Sectors: \(sectorTimes)
        Deltas to record: \(deltasToBest.joined(separator: "; "))
        Deltas to previous lap: \(deltasToPrevious.joined(separator: "; "))
        Recent laps (oldest to newest): \(recentLaps.joined(separator: ", "))

        Rules:
        - Use only the numbers above. Do not invent times, GPS data, coordinates or pace.
        - Be specific and short: one headline (max 8 words), a 1-2 sentence summary.
        - sectorNotes: one entry per sector that has a time, keyed by sector number.
        - hypotheses: at most 3, each a single testable idea about where time was gained or lost.
        - focusNext: at most 3 concrete things to work on next.
        """
    }
}

// MARK: - Request / schema

struct GeminiRequest: Codable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig

    struct GeminiContent: Codable { let parts: [GeminiPart] }
    struct GeminiPart: Codable { let text: String }

    struct GeminiGenerationConfig: Codable {
        let responseMimeType: String
        let responseSchema: GeminiSchema
    }

    init(payload: GeminiPayload) {
        self.contents = [GeminiContent(parts: [GeminiPart(text: payload.promptText)])]
        self.generationConfig = GeminiGenerationConfig(
            responseMimeType: "application/json",
            responseSchema: GeminiRequest.debriefSchema
        )
    }

    static let debriefSchema = GeminiSchema(
        type: "object",
        properties: [
            "headline": GeminiValue(type: "string", description: "Short punchy headline for the lap", items: nil, properties: nil, required: nil),
            "summary": GeminiValue(type: "string", description: "One or two sentences summarising the lap", items: nil, properties: nil, required: nil),
            "sectorNotes": GeminiValue(
                type: "array",
                description: "One note per sector",
                items: GeminiValue(
                    type: "object",
                    description: nil,
                    items: nil,
                    properties: [
                        "sector": GeminiValue(type: "integer", description: "Sector number 1-3", items: nil, properties: nil, required: nil),
                        "note": GeminiValue(type: "string", description: "Short note about the sector", items: nil, properties: nil, required: nil)
                    ],
                    required: ["sector", "note"]
                ),
                properties: nil,
                required: nil
            ),
            "hypotheses": GeminiValue(type: "array", description: "Up to 3 testable hypotheses", items: GeminiValue(type: "string", description: nil, items: nil, properties: nil, required: nil), properties: nil, required: nil),
            "focusNext": GeminiValue(type: "array", description: "Up to 3 focus points for the next session", items: GeminiValue(type: "string", description: nil, items: nil, properties: nil, required: nil), properties: nil, required: nil)
        ],
        required: ["headline", "summary", "sectorNotes"]
    )
}

struct GeminiSchema: Codable {
    let type: String
    let properties: [String: GeminiValue]
    let required: [String]
}

struct GeminiValue: Codable {
    let type: String
    let description: String?
    let items: GeminiValue?
    let properties: [String: GeminiValue]?
    let required: [String]?
}

// MARK: - Debrief payload (what the UI renders)

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
