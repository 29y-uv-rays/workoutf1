import XCTest
@testable import APEX

final class TimingEngineTests: XCTestCase {
    var engine: TimingEngine!

    override func setUp() { engine = TimingEngine() }

    // MARK: - Helpers

    private func makeSamples(points: [(lat: Double, lon: Double)], start: Date, interval: TimeInterval, hAcc: Double = 5.0, speed: Double = 2.5) -> [GPSSample] {
        points.enumerated().map { i, p in GPSSample(t: start.addingTimeInterval(Double(i) * interval), lat: p.lat, lon: p.lon, alt: nil, hAcc: hAcc, speed: speed) }
    }

    private func makeCircuit(name: String = "Test", activityType: ActivityType = .run, points: [(lat: Double, lon: Double)], isLoop: Bool = false, sectors: [SectorDefForEngine]? = nil, version: Int = 1) -> CircuitForEngine {
        let length = polylineLength(points)
        let defs: [SectorDefForEngine]
        if let s = sectors { defs = s } else {
            let third = length / 3.0
            defs = [SectorDefForEngine(index: 1, startDistanceMeters: 0, endDistanceMeters: third), SectorDefForEngine(index: 2, startDistanceMeters: third, endDistanceMeters: 2 * third), SectorDefForEngine(index: 3, startDistanceMeters: 2 * third, endDistanceMeters: length)]
        }
        return CircuitForEngine(id: UUID(), name: name, activityType: activityType, totalDistanceMeters: length, isLoop: isLoop, version: version, sectors: defs, polyline: points)
    }

    private func polylineLength(_ points: [(lat: Double, lon: Double)]) -> Double {
        var len: Double = 0
        for i in 1..<points.count { len += localDistance(lat1: points[i-1].lat, lon1: points[i-1].lon, lat2: points[i].lat, lon2: points[i].lon) }
        return len
    }

    // MARK: - GPS cleaning

    func testDropsBadAccuracy() {
        let start = Date()
        let good = GPSSample(t: start, lat: 0, lon: 0, hAcc: 4.0, speed: 2.0)
        let bad = GPSSample(t: start.addingTimeInterval(1), lat: 0.001, lon: 0, hAcc: 50.0, speed: 2.0)
        let cleaned = engine.clean([good, bad], activityType: .run)
        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned[0].t, good.t)
    }

    func testDropsDuplicateTimestamps() {
        let t = Date()
        let a = GPSSample(t: t, lat: 0, lon: 0, hAcc: 5.0)
        let b = GPSSample(t: t, lat: 0.001, lon: 0, hAcc: 5.0)
        let cleaned = engine.clean([a, b], activityType: .run)
        XCTAssertEqual(cleaned.count, 1)
    }

    func testKeepsValid() {
        let t = Date()
        let s = GPSSample(t: t, lat: 0, lon: 0, hAcc: 5.0, speed: 2.0)
        let cleaned = engine.clean([s], activityType: .run)
        XCTAssertEqual(cleaned.count, 1)
    }

    // MARK: - Matching

    func testMatchesSameActivityCorrectRange() {
        let pts = loopPoints()
        let circuit = makeCircuit(points: pts, isLoop: true)
        let samples = makeSamples(points: pts, start: Date(), interval: 5.0)
        let result = engine.matchRoute(samples: samples, circuit: circuit, activityType: .run)
        XCTAssertNotNil(result)
        if let r = result { XCTAssertTrue(r.match) } else { XCTFail() }
    }

    func testRejectsWrongActivity() {
        let pts = loopPoints()
        let circuit = makeCircuit(points: pts, isLoop: true, activityType: .run)
        let samples = makeSamples(points: pts, start: Date(), interval: 5.0)
        let result = engine.matchRoute(samples: samples, circuit: circuit, activityType: .walk)
        XCTAssertNotNil(result)
        if let r = result { XCTAssertFalse(r.match); XCTAssertNotNil(r.reason) } else { XCTFail() }
    }

    func testRejectsReverseDirection() {
        let pts = loopPoints()
        let circuit = makeCircuit(points: pts, isLoop: true)
        let samples = makeSamples(points: pts.reversed(), start: Date(), interval: 5.0)
        let result = engine.matchRoute(samples: samples, circuit: circuit, activityType: .run)
        XCTAssertNotNil(result)
        if let r = result { XCTAssertFalse(r.match); XCTAssertNotNil(r.reason) } else { XCTFail() }
    }

    func testRejectsDistanceTooLarge() {
        let pts = loopPoints()
        let circuit = makeCircuit(points: pts, isLoop: true)
        var longPts = pts
        longPts.append(contentsOf: [(pts.last!.lat + 0.001, pts.last!.lon + 0.001), (pts.last!.lat + 0.002, pts.last!.lon + 0.002)])
        let samples = makeSamples(points: longPts, start: Date(), interval: 5.0)
        let result = engine.matchRoute(samples: samples, circuit: circuit, activityType: .run)
        XCTAssertNotNil(result)
        if let r = result { XCTAssertFalse(r.match) } else { XCTFail() }
    }

    // MARK: - Projection

    func testProjectionNonDecreasingOnSelfTouchingLoop() {
        let pts = loopPointsWithSelfTouch()
        let circuit = makeCircuit(points: pts, isLoop: true)
        let samples = makeSamples(points: pts, start: Date(), interval: 5.0)
        let proj = engine.projectProgress(samples: samples, polyline: pts)
        XCTAssertEqual(proj.count, samples.count)
        for i in 1..<proj.count {
            XCTAssertGreaterThanOrEqual(proj[i].progress, proj[i-1].progress - 0.01)
        }
    }

    // MARK: - Boundary interpolation

    func testBoundaryInterpolation() {
        let pts = linearPoints(length: 1000.0, count: 100)
        let circuit = makeCircuit(points: pts, isLoop: false, sectors: [SectorDefForEngine(index: 1, startDistanceMeters: 0, endDistanceMeters: 500), SectorDefForEngine(index: 2, startDistanceMeters: 500, endDistanceMeters: 1000), SectorDefForEngine(index: 3, startDistanceMeters: 1000, endDistanceMeters: 1000)])
        let start = Date()
        let interval = 500.0 / Double(pts.count - 1) / 2.5
        let samples = makeSamples(points: pts, start: start, interval: interval)
        let proj = engine.projectProgress(samples: samples, polyline: pts)
        let crossing = engine.crossingTime(for: 500, projection: proj, samples: samples)
        XCTAssertNotNil(crossing)
        if let c = crossing {
            let midIdx = pts.count / 2
            let midT = start.addingTimeInterval(Double(midIdx) * interval)
            let dt = abs(c.timeIntervalSince(midT))
            XCTAssertLessThan(dt, interval * 1.5, "crossing should be near midpoint")
        }
    }

    // MARK: - Pause subtraction

    func testPauseSubtraction() {
        let pts = linearPoints(length: 1000.0, count: 50)
        let circuit = makeCircuit(points: pts, isLoop: false)
        let start = Date()
        let interval = 4.0
        let samples = makeSamples(points: pts, start: start, interval: interval)
        let pause = PauseInterval(start: start.addingTimeInterval(60), end: start.addingTimeInterval(120))
        let proj = engine.projectProgress(samples: samples, polyline: pts)
        let result = engine.computeSectorTimes(samples: samples, projection: proj, circuit: circuit, pauseIntervals: [pause])
        if let lt = result.lapTime {
            let expectedElapsed = samples.last!.t.timeIntervalSince(samples.first!.t)
            XCTAssertEqual(lt, expectedElapsed - 60.0, accuracy: 0.1)
        } else {
            XCTFail("Expected valid lap")
        }
    }

    // MARK: - Sector sum equals lap time

    func testSectorSumEqualsLapTime() {
        let pts = loopPoints()
        let circuit = makeCircuit(points: pts, isLoop: true)
        let start = Date()
        let samples = makeSamples(points: pts, start: start, interval: 5.0)
        let proj = engine.projectProgress(samples: samples, polyline: pts)
        let result = engine.computeSectorTimes(samples: samples, projection: proj, circuit: circuit, pauseIntervals: [])
        guard let lap = result.lapTime else { XCTFail("Expected valid lap"); return }
        let sum = result.sectorResults.compactMap(\.duration).reduce(0, +)
        XCTAssertEqual(sum, lap, accuracy: 0.011, "Sector sum must equal lap time within epsilon")
    }

    // MARK: - Colour classification

    func testFirstLapIsGrey() { XCTAssertEqual(engine.classify(current: 100, earlier: []), .grey) }
    func testNilTimeIsGrey() { XCTAssertEqual(engine.classify(current: nil, earlier: [90, 95]), .grey) }
    func testPurpleWhenFasterThanAll() { XCTAssertEqual(engine.classify(current: 90, earlier: [95, 98]), .purple) }
    func testGreenWhenImprovedOnPrevious() { XCTAssertEqual(engine.classify(current: 96, earlier: [95, 98]), .green) }
    func testYellowWhenSlowerThanPrevious() { XCTAssertEqual(engine.classify(current: 99, earlier: [95, 98]), .yellow) }
    func testTieIsNotFaster() { XCTAssertEqual(engine.classify(current: 95.0, earlier: [95.0, 98]), .yellow) }
    func testPurpleWithEpsilon() { XCTAssertEqual(engine.classify(current: 94.99, earlier: [95.0, 98]), .purple) }

    // MARK: - Recompute idempotence

    func testRecomputeIdempotent() {
        let pts = loopPoints()
        let circuit = makeCircuit(points: pts, isLoop: true, version: 1)
        let start = Date()
        let samples = makeSamples(points: pts, start: start, interval: 5.0)
        let proj = engine.projectProgress(samples: samples, polyline: pts)
        let r1 = engine.computeSectorTimes(samples: samples, projection: proj, circuit: circuit, pauseIntervals: [])
        let r2 = engine.computeSectorTimes(samples: samples, projection: proj, circuit: circuit, pauseIntervals: [])
        XCTAssertEqual(r1.lapTime, r2.lapTime, accuracy: 0.001)
        XCTAssertEqual(r1.sectorResults.count, r2.sectorResults.count)
        for i in 0..<r1.sectorResults.count {
            XCTAssertEqual(r1.sectorResults[i].duration, r2.sectorResults[i].duration, accuracy: 0.001)
        }
    }

    // MARK: - Partial / missing

    func testFewSamplesYieldsPartial() {
        let samples = [GPSSample(t: Date(), lat: 0, lon: 0, hAcc: 5.0)]
        let circuit = makeCircuit(points: loopPoints(), isLoop: true)
        let input = WorkoutForEngine(sourceWorkoutUUID: "x", activityType: .run, startDate: Date(), endDate: Date(), durationSeconds: 0, distanceMeters: 0, samples: samples, hasRoute: true, pauseIntervals: [], circuit: circuit, circuitVersion: 1, algorithmVersion: TimingEngine.algorithmVersion)
        let result = engine.analyse(input)
        XCTAssertEqual(result.lapTime, nil)
        XCTAssertFalse(result.isValid)
    }
}

// MARK: - Sample data helpers

private func loopPoints() -> [(lat: Double, lon: Double)] {
    let base = (lat: 51.5074, lon: -0.1278)
    var pts: [(lat: Double, lon: Double)] = []
    let n = 300
    for i in 0..<n {
        let t = Double(i) / Double(n) * 2 * .pi
        let r = 0.0008
        let x = r * cos(t)
        let y = r * sin(t) * 0.7
        let lat = base.lat + y / 111320.0
        let lon = base.lon + x / (111320.0 * cos(base.lat * .pi / 180.0))
        pts.append((lat: lat, lon: lon))
    }
    pts[0] = (base.lat, base.lon)
    pts[n-1] = (base.lat + 0.000001, base.lon + 0.000001)
    return pts
}

private func loopPointsWithSelfTouch() -> [(lat: Double, lon: Double)] {
    let base = (lat: 51.5074, lon: -0.1278)
    var pts: [(lat: Double, lon: Double)] = []
    let n = 400
    for i in 0..<n {
        let t = Double(i) / Double(n) * 2 * .pi
        let r1 = 0.0008
        let r2 = 0.0004
        let x = r1 * cos(t) + r2 * cos(2 * t) * 0.3
        let y = r2 * sin(2 * t) * 0.3 + r1 * sin(t) * 0.6
        let lat = base.lat + y / 111320.0
        let lon = base.lon + x / (111320.0 * cos(base.lat * .pi / 180.0))
        pts.append((lat: lat, lon: lon))
    }
    pts[0] = (base.lat, base.lon)
    pts[n-1] = (base.lat + 0.000001, base.lon + 0.000001)
    return pts
}

private func linearPoints(length: Double, count: Int) -> [(lat: Double, lon: Double)] {
    let base = (lat: 51.5074, lon: -0.1278)
    var pts: [(lat: Double, lon: Double)] = [(base.lat, base.lon)]
    let step = length / Double(count - 1) / 111320.0
    for i in 1..<count {
        let lat = base.lat + step * Double(i) / cos(base.lat * .pi / 180.0)
        let lon = base.lon
        pts.append((lat: lat, lon: lon))
    }
    return pts
}

private func localDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let r = 6371000.0
    let x = (lon2 - lon1) * .pi / 180.0 * cos((lat1 + lat2) / 2 * .pi / 180.0) * r
    let y = (lat2 - lat1) * .pi / 180.0 * r
    return hypot(x, y)
}

// MARK: - Compile-time helpers for tests referencing engine internals.

extension TimingEngine {
    func matchRoute(samples: [GPSSample], circuit: CircuitForEngine, activityType: ActivityType) -> MatchResult? {
        return matchRoute(samples: samples, circuit: circuit, activityType: activityType)
    }

    func projectProgress(samples: [GPSSample], polyline: [(lat: Double, lon: Double)]) -> [SampleProjection] {
        return projectProgress(samples: samples, polyline: polyline)
    }

    func computeSectorTimes(samples: [GPSSample], projection: [SampleProjection], circuit: CircuitForEngine, pauseIntervals: [PauseInterval]) -> SectorTimingResult {
        return computeSectorTimes(samples: samples, projection: projection, circuit: circuit, pauseIntervals: pauseIntervals)
    }

    func crossingTime(for distance: Double, projection: [SampleProjection], samples: [GPSSample]) -> Date? {
        return crossingTime(for: distance, projection: projection, samples: samples)
    }

    func clean(_ samples: [GPSSample], activityType: ActivityType) -> [GPSSample] {
        return clean(samples, activityType: activityType)
    }

}
