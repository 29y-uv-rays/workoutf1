import Foundation
import CoreLocation

// MARK: - Config

struct TimingConfig: Sendable {
    let accuracyCapMeters: Double = 30.0
    let minSamples: Int = 20
    let maxGapSeconds: Double = 30.0
    let plausibilityCap: [ActivityType: Double] = [.run: 12.0, .walk: 5.0, .cycle: 25.0]
    let startEndProximityMeters: Double = 50.0
    let distanceToleranceFraction: Double = 0.10
    let medianTrackToPolylineMeters: Double = 30.0
    let p90TrackToPolylineMeters: Double = 60.0
    let directionProgressMinFraction: Double = 0.5
    let projectionWindowAheadMeters: Double = 150.0
    let projectionWindowBehindMeters: Double = 20.0
    let crossingDebounceTime: Double = 10.0
    let crossingDebounceDistance: Double = 15.0
    let minSectorFraction: Double = 0.05
    let epsilon: Double = 0.01

    static let `default` = TimingConfig()
}

// MARK: - Engine

struct TimingEngine: Sendable {
    let config: TimingConfig
    static let algorithmVersion = 1

    init(config: TimingConfig = .default) { self.config = config }

    // MARK: - Public entry

    func analyse(_ input: WorkoutForEngine) -> LapAnalysisResult {
        let cleaned = clean(input.samples, activityType: input.activityType)
        guard cleaned.count >= config.minSamples else {
            return LapAnalysisResult(lapTime: nil, lapColour: nil, sectorResults: [], isValid: false, reason: "Too few GPS samples after cleaning", matchScore: 0)
        }
        guard let match = matchRoute(samples: cleaned, circuit: input.circuit, activityType: input.activityType) else {
            return LapAnalysisResult(lapTime: nil, lapColour: nil, sectorResults: [], isValid: false, reason: match.reason ?? "No route match", matchScore: 0)
        }
        let projection = projectProgress(samples: cleaned, polyline: match.polyline)
        guard hasValidSpan(samples: cleaned, projection: projection, circuit: input.circuit) else {
            return LapAnalysisResult(lapTime: nil, lapColour: nil, sectorResults: [], isValid: false, reason: "No valid circuit span", matchScore: match.score)
        }
        let lapResult = computeSectorTimes(samples: cleaned, projection: projection, circuit: input.circuit, pauseIntervals: input.pauseIntervals)
        return LapAnalysisResult(lapTime: lapResult.lapTime, lapColour: nil, sectorResults: lapResult.sectorResults.map { SectorResultForEngine(duration: $0.duration, colour: nil) }, isValid: lapResult.isValid, reason: lapResult.reason, matchScore: match.score)
    }

    func classify(current: Double?, earlier: [Double]) -> SectorColor {
        guard let current else { return .grey }
        guard !earlier.isEmpty else { return .grey }
        let best = earlier.min() ?? current
        let previous = earlier.last ?? current
        if current < best - config.epsilon { return .purple }
        if current < previous - config.epsilon { return .green }
        return .yellow
    }

    // MARK: - Cleaning

    private func clean(_ samples: [GPSSample], activityType: ActivityType) -> [GPSSample] {
        let cap = config.plausibilityCap[activityType] ?? 12.0
        var kept: [GPSSample] = []
        for s in samples {
            let hAcc = s.hAcc ?? Double.infinity
            if hAcc < 0 || hAcc > config.accuracyCapMeters { continue }
            if let spd = s.speed, spd > cap { continue }
            kept.append(s)
        }
        kept.sort { $0.t < $1.t }
        var out: [GPSSample] = []
        var lastT: Date?
        for s in kept {
            if let lt = lastT, s.t == lt { continue }
            out.append(s)
            lastT = s.t
        }
        return out
    }

    // MARK: - Matching

    private struct MatchResult { let match: Bool; let score: Double; let reason: String?; let polyline: [(lat: Double, lon: Double)] }

    private func matchRoute(samples: [GPSSample], circuit: CircuitForEngine, activityType: ActivityType) -> MatchResult? {
        guard let first = samples.first, let last = samples.last else { return nil }
        guard circuit.activityType == activityType else { return MatchResult(match: false, score: 0, reason: "Activity type mismatch", polyline: []) }
        let polyline = circuit.polyline
        guard polyline.count >= 2 else { return MatchResult(match: false, score: 0, reason: "Circuit polyline too short", polyline: []) }

        let startDist = localDistance(lat1: first.lat, lon1: first.lon, lat2: polyline.first!.lat, lon2: polyline.first!.lon)
        let endDist: Double
        if circuit.isLoop {
            endDist = localDistance(lat1: last.lat, lon1: last.lon, lat2: polyline.first!.lat, lon2: polyline.first!.lon)
        } else {
            endDist = localDistance(lat1: last.lat, lon1: last.lon, lat2: polyline.last!.lat, lon2: polyline.last!.lon)
        }
        guard startDist <= config.startEndProximityMeters && endDist <= config.startEndProximityMeters else {
            return MatchResult(match: false, score: 0, reason: "Start/end not near circuit", polyline: polyline)
        }

        let routeLen = samples.reduce(0.0) { acc, s in
            guard acc > 0 || true else { return acc }
            return acc + localDistance(lat1: (acc == 0 ? s.lat : samples[samples.firstIndex(where: { _ in false }) ?? 0].lat), lon1: 0, lat2: s.lat, lon2: s.lon)
        }
        // simpler: compute actual route length
        var len: Double = 0
        for i in 1..<samples.count {
            len += localDistance(lat1: samples[i-1].lat, lon1: samples[i-1].lon, lat2: samples[i].lat, lon2: samples[i].lon)
        }
        let tol = circuit.totalDistanceMeters * config.distanceToleranceFraction
        guard abs(len - circuit.totalDistanceMeters) <= tol else {
            return MatchResult(match: false, score: 0, reason: "Distance outside tolerance", polyline: polyline)
        }

        let dists = samples.map { sampleToPolylineDistance(lat: $0.lat, lon: $0.lon, polyline: polyline) }
        guard let median = percentile(dists: dists, p: 0.5), median <= config.medianTrackToPolylineMeters else {
            return MatchResult(match: false, score: 0, reason: "Median track-to-polyline too large", polyline: polyline)
        }
        guard let p90 = percentile(dists: dists, p: 0.9), p90 <= config.p90TrackToPolylineMeters else {
            return MatchResult(match: false, score: 0, reason: "90th percentile track-to-polyline too large", polyline: polyline)
        }

        let proj = projectProgress(samples: samples, polyline: polyline)
        guard proj.count >= 2 else { return MatchResult(match: false, score: 0, reason: "Projection failed", polyline: polyline) }
        let firstProg = proj[0].progress
        let lastProg = proj[proj.count - 1].progress
        let progressGain = circuit.isLoop ? (lastProg - firstProg + circuit.totalDistanceMeters).truncatingRemainder(dividingBy: circuit.totalDistanceMeters) : (lastProg - firstProg)
        let minGain = circuit.totalDistanceMeters * config.directionProgressMinFraction
        guard progressGain >= minGain else { return MatchResult(match: false, score: 0, reason: "Reverse or no overall progress", polyline: polyline) }

        let score = 1.0 - abs(len - circuit.totalDistanceMeters) / circuit.totalDistanceMeters
        return MatchResult(match: true, score: max(0, score), reason: nil, polyline: polyline)
    }

    // MARK: - Projection

    private struct SampleProjection { let t: Date; let lat: Double; let lon: Double; let progress: Double }

    private func projectProgress(samples: [GPSSample], polyline: [(lat: Double, lon: Double)]) -> [SampleProjection] {
        guard polyline.count >= 2 else { return [] }
        let total = polylineLength(polyline)
        var out: [SampleProjection] = []
        var prevProg: Double?
        for s in samples {
            let windowStart: Double = prevProg.map { max(0, $0 - config.projectionWindowBehindMeters) } ?? 0
            let windowEnd: Double = min(total, (prevProg ?? 0) + config.projectionWindowAheadMeters)
            let prog = projectOntoWindow(lat: s.lat, lon: s.lon, polyline: polyline, total: total, windowStart: windowStart, windowEnd: windowEnd)
            let clamped = clampNonDecreasing(prog: prog, prev: prevProg)
            out.append(SampleProjection(t: s.t, lat: s.lat, lon: s.lon, progress: clamped))
            prevProg = clamped
        }
        return out
    }

    private func polylineLength(_ polyline: [(lat: Double, lon: Double)]) -> Double {
        var len: Double = 0
        for i in 1..<polyline.count { len += localDistance(lat1: polyline[i-1].lat, lon1: polyline[i-1].lon, lat2: polyline[i].lat, lon2: polyline[i].lon) }
        return len
    }

    private func projectOntoWindow(lat: Double, lon: Double, polyline: [(lat: Double, lon: Double)], total: Double, windowStart: Double, windowEnd: Double) -> Double {
        var cum: Double = 0
        var bestProg = windowStart
        var bestDist = Double.infinity
        for i in 0..<polyline.count-1 {
            let segStart = cum
            let segLen = localDistance(lat1: polyline[i].lat, lon1: polyline[i].lon, lat2: polyline[i+1].lat, lon2: polyline[i+1].lon)
            let segEnd = cum + segLen
            cum = segEnd
            if segEnd < windowStart || segStart > windowEnd { continue }
            if let (_, _, t, _) = projectOntoSegmentVisible(pLat: lat, pLon: lon, aLat: polyline[i].lat, aLon: polyline[i].lon, bLat: polyline[i+1].lat, bLon: polyline[i+1].lon) {
                let prog = segStart + segLen * t
                if prog < windowStart || prog > windowEnd { continue }
                let d = localDistance(lat1: lat, lon1: lon, lat2: polyline[i].lat + (polyline[i+1].lat - polyline[i].lat) * t, lon2: polyline[i].lon + (polyline[i+1].lon - polyline[i].lon) * t)
                if d < bestDist { bestDist = d; bestProg = prog }
            }
        }
        return bestProg
    }

    private func projectOntoSegmentVisible(pLat: Double, pLon: Double, aLat: Double, aLon: Double, bLat: Double, bLon: Double) -> (clat: Double, clon: Double, t: Double, dist: Double)? {
        guard let (_, _, t, _) = projectOntoSegment(pLat: pLat, pLon: pLon, aLat: aLat, aLon: aLon, bLat: bLat, bLon: bLon) else { return nil }
        return (aLat + (bLat - aLat) * t, aLon + (bLon - aLon) * t, t, 0)
    }

    private func clampNonDecreasing(prog: Double, prev: Double?) -> Double {
        if let prev = prev {
            if prog < prev - 0.01 { return prev }
            if prog < prev { return prev }
        }
        return prog
    }

    // MARK: - Geometry

    private func localDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371000.0
        let x = (lon2 - lon1) * .pi / 180.0 * cos((lat1 + lat2) / 2 * .pi / 180.0) * r
        let y = (lat2 - lat1) * .pi / 180.0 * r
        return hypot(x, y)
    }

    private func sampleToPolylineDistance(lat: Double, lon: Double, polyline: [(lat: Double, lon: Double)]) -> Double {
        var best: Double = Double.infinity
        for i in 0..<polyline.count-1 {
            if let (_, _, _, dist) = projectOntoSegment(pLat: lat, pLon: lon, aLat: polyline[i].lat, aLon: polyline[i].lon, bLat: polyline[i+1].lat, bLon: polyline[i+1].lon) {
                if dist < best { best = dist }
            }
        }
        return best
    }

    private func percentile(dists: [Double], p: Double) -> Double? {
        guard !dists.isEmpty else { return nil }
        let sorted = dists.sorted()
        let idx = Int(Double(sorted.count - 1) * p)
        return sorted[Swift.max(0, Swift.min(sorted.count-1, idx))]
    }

    // MARK: - Segment projection

    private func projectOntoSegment(pLat: Double, pLon: Double, aLat: Double, aLon: Double, bLat: Double, bLon: Double) -> (clat: Double, clon: Double, t: Double, dist: Double)? {
        let r = 6371000.0
        let cosLat = cos((aLat + bLat) / 2 * .pi / 180.0)
        let ax = (aLon - pLon) * .pi / 180.0 * cosLat * r
        let ay = (aLat - pLat) * .pi / 180.0 * r
        let bx = (bLon - pLon) * .pi / 180.0 * cosLat * r
        let by = (bLat - pLat) * .pi / 180.0 * r
        let dx = bx - ax
        let dy = by - ay
        let len2 = dx*dx + dy*dy
        guard len2 > 1e-6 else { return nil }
        let tLocal = ((pLon - aLon) * .pi / 180.0 * cosLat * r * dx + (pLat - aLat) * .pi / 180.0 * r * dy) / len2
        let tt = max(0, min(1, tLocal))
        let cx = ax + dx * tt
        let cy = ay + dy * tt
        let clat = pLat + cy / r * 180.0 / .pi
        let clon = pLon + cx / (cosLat * r) * 180.0 / .pi
        let dist = sqrt(cx*cx + cy*cy)
        return (clat, clon, tt, dist)
    }

    // MARK: - Span + gap

    private func hasValidSpan(samples: [GPSSample], projection: [SampleProjection], circuit: CircuitForEngine) -> Bool {
        let total = circuit.totalDistanceMeters
        let span = projection.enumerated().compactMap { (i, p) in
            if p.progress >= 0 && p.progress <= total { return (t: p.t, lat: samples[i].lat, lon: samples[i].lon, prog: p.progress) }
            return nil
        }
        guard span.count >= config.minSamples else { return false }
        for i in 1..<span.count {
            if span[i].t.timeIntervalSince(span[i-1].t) > config.maxGapSeconds { return false }
        }
        return true
    }

    // MARK: - Sector times

    private struct SectorTimingResult { let lapTime: Double?; let sectorResults: [(index: Int, duration: Double?, reason: String?)]; let isValid: Bool; let reason: String? }

    private func computeSectorTimes(samples: [GPSSample], projection: [SampleProjection], circuit: CircuitForEngine, pauseIntervals: [PauseInterval]) -> SectorTimingResult {
        let total = circuit.totalDistanceMeters
        let sectors = circuit.sectors

        let boundaries: [(Int, Double)] = [
            (0, 0),
            (1, sectors[safe: 0].endDistanceMeters ?? sectors.first(where: { $0.index == 1 })?.endDistanceMeters ?? 0),
            (2, sectors[safe: 1].endDistanceMeters ?? sectors.first(where: { $0.index == 2 })?.endDistanceMeters ?? total),
            (3, total),
        ]

        var crossings: [(idx: Int, distance: Double, time: Date?)] = []
        for (idx, dist) in boundaries where dist <= total {
            crossings.append((idx: idx, distance: dist, time: crossingTime(for: dist, projection: projection, samples: samples)))
        }
        crossings = debounceCrossings(crossings)

        guard let startCross = crossings.first(where: { $0.idx == 0 }) else {
            return SectorTimingResult(lapTime: nil, sectorResults: [], isValid: false, reason: "Start boundary not crossed")
        }
        guard let endCross = crossings.last(where: { $0.idx == 3 || $0.distance == total }) else {
            return SectorTimingResult(lapTime: nil, sectorResults: [], isValid: false, reason: "Finish boundary not crossed")
        }

        guard let startT = startCross.time, let endT = endCross.time else {
            return SectorTimingResult(lapTime: nil, sectorResults: [], isValid: false, reason: "Missing crossing timestamps")
        }

        let lapElapsed = endT.timeIntervalSince(startT)
        guard lapElapsed >= 0 else { return SectorTimingResult(lapTime: nil, sectorResults: [], isValid: false, reason: "Lap start after finish") }

        let pausedInLap = pauseIntervals.reduce(0.0) { $0 + $1.overlapDuration(withinStart: startT, withinEnd: endT) }
        let lapMoving = lapElapsed - pausedInLap
        if lapMoving < 0 { return SectorTimingResult(lapTime: nil, sectorResults: [], isValid: false, reason: "Negative moving time after pause subtraction") }

        // Plausibility: implied speed vs cap.
        let cap = config.plausibilityCap[circuit.activityType] ?? 12.0
        if circuit.totalDistanceMeters / max(0.01, lapMoving) > cap {
            return SectorTimingResult(lapTime: lapMoving, sectorResults: [], isValid: false, reason: "Implied average speed exceeds plausibility cap for \(circuit.activityType.displayName)")
        }

        var sectorResults: [(index: Int, duration: Double?, reason: String?)] = []
        for s in sectors {
            guard let crossStart = crossings.first(where: { $0.distance == s.startDistanceMeters })?.time,
                  let crossEnd = crossings.first(where: { $0.distance == s.endDistanceMeters })?.time else {
                sectorResults.append((index: s.index, duration: nil, reason: "Missing boundary crossing"))
                continue
            }
            let secElapsed = crossEnd.timeIntervalSince(crossStart)
            guard secElapsed >= 0 else {
                sectorResults.append((index: s.index, duration: nil, reason: "Sector start after end"))
                continue
            }
            let pausedInSec = pauseIntervals.reduce(0.0) { $0 + $1.overlapDuration(withinStart: crossStart, withinEnd: crossEnd) }
            let secMoving = secElapsed - pausedInSec
            if secMoving < 0 {
                sectorResults.append((index: s.index, duration: nil, reason: "Negative after pause subtraction"))
            } else {
                sectorResults.append((index: s.index, duration: secMoving, reason: nil))
            }
        }

        let sum = sectorResults.compactMap(\.duration).reduce(0, +)
        if abs(sum - lapMoving) > config.epsilon {
            return SectorTimingResult(lapTime: lapMoving, sectorResults: sectorResults, isValid: false, reason: "Sector times do not sum to lap time (diff \(String(format: "%.2f", abs(sum - lapMoving)))s)")
        }

        return SectorTimingResult(lapTime: lapMoving, sectorResults: sectorResults, isValid: true, reason: nil)
    }

    private func crossingTime(for distance: Double, projection: [SampleProjection], samples: [GPSSample]) -> Date? {
        guard projection.count >= 2 else { return nil }
        var prev: SampleProjection?
        for cur in projection {
            if cur.progress >= distance {
                if let p = prev, p.progress < distance {
                    let frac = (distance - p.progress) / max(0.0001, (cur.progress - p.progress))
                    return p.t.addingTimeInterval(cur.t.timeIntervalSince(p.t) * frac)
                } else {
                    return cur.t
                }
            }
            prev = cur
        }
        return projection.last?.t
    }

    private func debounceCrossings(_ crossings: [(idx: Int, distance: Double, time: Date?)]) -> [(idx: Int, distance: Double, time: Date?)] {
        var result: [(idx: Int, distance: Double, time: Date?)] = []
        for c in crossings {
            let tooSoon = result.contains { prev in
                prev.idx == c.idx && prev.time != nil && c.time != nil &&
                c.time!.timeIntervalSince(prev.time!) < config.crossingDebounceTime &&
                abs(prev.distance - c.distance) < config.crossingDebounceDistance
            }
            if !tooSoon { result.append(c) }
        }
        return result
    }
}

// MARK: - Subscript helper

extension Array {
    subscript safe index: Int -> Element? {
        get { indices.contains(index) ? self[index] : nil }
    }
}
