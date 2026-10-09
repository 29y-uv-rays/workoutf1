import SwiftUI
import MapKit
import SwiftData

struct LapDetailView: View {
    let workout: Workout
    let circuit: Circuit

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workout.startDate, order: .reverse) private var allWorkouts: [Workout]
    @State private var comparison: ComparisonScope = .routeRecord

    enum ComparisonScope: String, CaseIterable { case routeRecord = "Route record"; case previousLap = "Previous lap" }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerSection
                mapSection
                sectorBlocksSection
                lapTimeSection
                comparisonSelectorSection
                raceEngineerSection
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle("Lap details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(circuit.name).font(.title2).fontWeight(.semibold).foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                Text(workout.activityType.displayName).font(.caption).foregroundStyle(Theme.secondaryText)
                Text("•").foregroundStyle(Theme.secondaryText)
                Text(workout.startDate.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(Theme.secondaryText)
                Text("•").foregroundStyle(Theme.secondaryText)
                Text(String(format: "%.2f km", circuit.totalDistanceMeters / 1000.0)).font(.caption).foregroundStyle(Theme.secondaryText)
            }
            if workout.timingStatus != .valid {
                Text(timingStatusNote).font(.caption).foregroundStyle(Theme.grey)
            }
        }
    }

    private var timingStatusNote: String {
        switch workout.timingStatus {
        case .missingGPS: return "No GPS route recorded for this workout — no telemetry."
        case .partial: return "Partial GPS — sector times may be incomplete."
        case .unmatched, .pending: return "Not yet matched to a circuit."
        case .valid: return ""
        case .needsCircuitChoice: return "This workout could match more than one circuit."
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        Group {
            if let route = PersistenceController.shared.fileStore.loadRouteJSON(for: workout.sourceWorkoutUUID) {
                Map {
                    if route.isEmpty { } else {
                        let first = route.first!, last = route.last!
                        Annotation("S/F", coordinate: CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon)) { Image(systemName: "flag.fill").foregroundStyle(Theme.purple).font(.title3) }
                        Annotation("A", coordinate: circuit.boundaryCoordinate(at: fracA, points: route)) { Image(systemName: "mappin.circle.fill").foregroundStyle(SectorColor.green.color).font(.title3) }
                        Annotation("B", coordinate: circuit.boundaryCoordinate(at: fracB, points: route)) { Image(systemName: "mappin.circle.fill").foregroundStyle(SectorColor.yellow.color).font(.title3) }
                        ForEach(1...3, id: \.self) { idx in
                            let slice = sectorRouteSlice(for: idx, points: route)
                            if slice.count > 1 { MapPolyline(coordinates: slice).stroke(sectorColour(for: idx), lineWidth: 4) }
                        }
                    }
                }
                .mapStyle(.standard)
                .mapRotationTap(false)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface).frame(height: 220).overlay(VStack(spacing: 6) { Image(systemName: "mappin.slash").foregroundStyle(Theme.grey); Text("No route map").font(.caption).foregroundStyle(Theme.secondaryText) })
            }
        }
    }

    private var fracA: Double {
        guard let defA = circuit.sectorDefinition(at: 2) else { return 1.0/3.0 }
        return defA.startDistanceMeters / circuit.totalDistanceMeters
    }

    private var fracB: Double {
        guard let defB = circuit.sectorDefinition(at: 3) else { return 2.0/3.0 }
        return defB.startDistanceMeters / circuit.totalDistanceMeters
    }

    private func sectorRouteSlice(for idx: Int, points: [MapPoint]) -> [CLLocationCoordinate2D] {
        guard let def = circuit.sectorDefinition(at: idx) else { return [] }
        return points.enumerated().compactMap { (i, p) in
            let d = Double(i) / Double(max(1, points.count - 1)) * circuit.totalDistanceMeters
            if d >= def.startDistanceMeters && d <= def.endDistanceMeters { return CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }
            return nil
        }
    }

    private func sectorColour(for idx: Int) -> Color {
        let r = sectorResult(for: idx)
        return (r?.colour ?? .grey).color
    }

    // MARK: - Sector blocks

    private var sectorBlocksSection: some View {
        VStack(spacing: 10) {
            Text("SECTORS").font(.labelCaps).foregroundStyle(Theme.secondaryText)
            ForEach(1...3, id: \.self) { idx in
                SectorBlock(sectorIndex: idx, result: sectorResult(for: idx), best: bestTime(for: idx), previous: previousTime(for: idx), comparison: comparison)
            }
        }
    }

    // MARK: - Lap time

    private var lapTimeSection: some View {
        Panel {
            VStack(spacing: 8) {
                HStack {
                    Text("LAP TIME").font(.labelCaps).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    if let lt = workout.lapTimeSeconds {
                        Text(TimeFormat.absolute(lt)).font(.timingBoard).monospacedDigits().foregroundStyle(Theme.text)
                    } else {
                        Text("—").font(.timingBoard).monospacedDigits().foregroundStyle(Theme.grey)
                    }
                }
                if let lt = workout.lapTimeSeconds {
                    if let best = bestLapTime(), let prev = previousLapTime() {
                        HStack(spacing: 16) {
                            deltaBlock(label: "vs record", delta: lt - best)
                            deltaBlock(label: "vs previous", delta: lt - prev)
                        }
                    }
                }
                Text("GPS timing is approximate: sample rate, GPS drift and boundary interpolation affect results. Times shown to 0.01 s for the timing-board feel, but that precision is not real. Invalid or partial laps show their reason.").font(.caption2).foregroundStyle(Theme.grey).lineLimit(3)
            }
        }
    }

    private func deltaBlock(label: String, delta: Double) -> some View {
        let faster = delta < -0.005
        let slower = delta > 0.005
        return HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(Theme.secondaryText)
            Text(TimeFormat.delta(delta)).font(.timingBoardSmall).monospacedDigits().foregroundStyle(faster ? Theme.green : (slower ? Theme.yellow : Theme.text))
            if faster { Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.green).font(.caption) }
            else if slower { Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.yellow).font(.caption) }
        }
    }

    // MARK: - Comparison selector

    private var comparisonSelectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COMPARISON").font(.labelCaps).foregroundStyle(Theme.secondaryText)
            Picker("Comparison", selection: $comparison) {
                ForEach(ComparisonScope.allCases, id: \.self) { scope in Text(scope.rawValue).tag(scope) }
            }
            .pickerStyle(.segmented)
            .tint(Theme.purple)
        }
    }

    // MARK: - Race engineer

    private var raceEngineerSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("RACE ENGINEER").font(.labelCaps).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    if debrief != nil { Text("Cached").font(.caption).foregroundStyle(Theme.secondaryText) }
                }
                if let debrief = debrief, let payload = debrief.payload() {
                    Text(payload.headline).font(.subheadline).fontWeight(.medium).foregroundStyle(Theme.text).lineLimit(2)
                    Text(payload.summary).font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(4)
                    if !payload.sectorNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(payload.sectorNotes.enumerated()), id: \.element.sector) { _, note in Text(note.note).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2) }
                        }
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            sendPreviewBlock
                            if let hyp = payload.hypotheses, !hyp.isEmpty {
                                Text("Hypotheses").font(.caption).fontWeight(.semibold).foregroundStyle(Theme.secondaryText.opacity(0.8))
                                ForEach(Array(hyp.enumerated()), id: \.element) { _, h in Text("• \(h)").font(.caption).foregroundStyle(Theme.secondaryText) }
                            }
                            if let focus = payload.focusNext, !focus.isEmpty {
                                Text("Focus next").font(.caption).fontWeight(.semibold).foregroundStyle(Theme.secondaryText.opacity(0.8))
                                ForEach(Array(focus.enumerated()), id: \.element) { _, f in Text("• \(f)").font(.caption).foregroundStyle(Theme.secondaryText) }
                            }
                            Text("AI-generated analysis. All times are computed locally by APEX.").font(.caption2).foregroundStyle(Theme.grey)
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack { Circle().fill(Theme.purple).frame(width: 6, height: 6); Text("View data sent").font(.caption).foregroundStyle(Theme.secondaryText) }
                    }
                    .font(.caption)
                } else {
                    Button {
                        Task { await requestRaceEngineer() }
                    } label: {
                        Label("Ask your Race Engineer", systemImage: "mic.fill").font(.subheadline).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.purple).controlSize(.large).disabled(!KeychainService.shared.hasGeminiKey)
                }
            }
        }
    }

    private var sendPreviewBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This lap sends only:").font(.caption).fontWeight(.semibold).foregroundStyle(Theme.secondaryText.opacity(0.8))
            Text(buildSendPreview).font(.caption).foregroundStyle(Theme.text).lineLimit(6)
        }
    }

    private var buildSendPreview: String {
        var parts = ["Circuit: \(circuit.name)", "Activity: \(workout.activityType.displayName)", "Date: \(workout.startDate.formatted(.dateTime.day().month().year()))"]
        if let lt = workout.lapTimeSeconds { parts.append("Lap: \(TimeFormat.absolute(lt))") } else { parts.append("Lap: —") }
        for idx in 1...3 {
            if let r = sectorResult(for: idx) { parts.append("S\(idx): \(TimeFormat.absolute(r.durationSeconds ?? 0))") } else { parts.append("S\(idx): —") }
        }
        parts.append("No coordinates, no raw GPS, no names.")
        return parts.joined(separator: " • ")
    }

    // MARK: - Helpers

    private func sectorResult(for sectorIndex: Int) -> SectorResult? {
        let desc = FetchDescriptor<SectorResult>(predicate: #Predicate { $0.workouUUID == workout.sourceWorkoutUUID && $0.sectorIndex == sectorIndex })
        return (try? modelContext.fetch(desc)).flatMap { $0.first }
    }

    private func bestTime(for sectorIndex: Int) -> Double? { bestSectorTime(for: sectorIndex) }
    private func previousTime(for sectorIndex: Int) -> Double? { previousSectorTime(for: sectorIndex) }
    private func bestLapTime() -> Double? { Circuit.bestLapTime(for: circuit, modelContext: modelContext) }
    private func previousLapTime() -> Double? { previousLap()?.lapTimeSeconds }

    private func bestSectorTime(for sectorIndex: Int) -> Double? {
        let laps = Workout.fetchValidLaps(for: circuit, modelContext: modelContext)
        var best: Double?
        for w in laps {
            let desc = FetchDescriptor<SectorResult>(predicate: #Predicate { $0.workouUUID == w.sourceWorkoutUUID && $0.sectorIndex == sectorIndex })
            if let r = (try? modelContext.fetch(desc)).flatMap({ $0.first }), let d = r.durationSeconds {
                if best == nil || d < best! { best = d }
            }
        }
        return best
    }

    private func previousSectorTime(for sectorIndex: Int) -> Double? {
        guard let prev = previousLap() else { return nil }
        let desc = FetchDescriptor<SectorResult>(predicate: #Predicate { $0.workouUUID == prev.sourceWorkoutUUID && $0.sectorIndex == sectorIndex })
        return (try? modelContext.fetch(desc)).flatMap { $0.first }?.durationSeconds
    }

    private func previousLap() -> Workout? {
        let desc = FetchDescriptor<Workout>(predicate: #Predicate { w in w.circuit?.id == circuit.id && w.timingStatus == .valid && w.circuitVersion == circuit.version && w.algorithmVersion == TimingEngine.algorithmVersion && w.startDate < workout.startDate }, sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        return (try? modelContext.fetch(desc)).flatMap { $0.first }
    }

    private var debrief: RaceEngineerDebrief? {
        let desc = FetchDescriptor<RaceEngineerDebrief>(predicate: #Predicate { $0.workouUUID == workout.sourceWorkoutUUID })
        return (try? modelContext.fetch(desc)).flatMap { $0.first }
    }

    private func requestRaceEngineer() async {
        await GeminiService.shared.debrief(for: workout, modelContext: modelContext)
    }
}

// MARK: - Sector block view

struct SectorBlock: View {
    let sectorIndex: Int
    let result: SectorResult?
    let best: Double?
    let previous: Double?
    let comparison: LapDetailView.ComparisonScope

    var body: some View {
        let dur = result?.durationSeconds
        let colour = result?.colour ?? .grey
        let target: Double? = comparison == .routeRecord ? best : previous
        let delta = target.flatMap { dur.map { $0 - $1 } }
        VStack(spacing: 6) {
            HStack {
                Text("S\(sectorIndex)").font(.sectorTag).foregroundStyle(colour.color)
                Text(colour.glyph).font(.system(size: 11, weight: .bold, design: .default)).foregroundStyle(colour.color)
                Spacer()
                if let d = dur {
                    Text(TimeFormat.absolute(d)).font(.timingBoard).monospacedDigits().foregroundStyle(Theme.text)
                } else {
                    Text("—").font(.timingBoard).monospacedDigits().foregroundStyle(Theme.grey)
                }
            }
            if let delta = delta {
                HStack(spacing: 4) {
                    Image(systemName: delta < -0.005 ? "arrow.down.circle.fill" : (delta > 0.005 ? "arrow.up.circle.fill" : "circle.fill")).foregroundStyle(delta < -0.005 ? Theme.green : (delta > 0.005 ? Theme.yellow : Theme.secondaryText)).font(.caption)
                    Text(TimeFormat.delta(delta)).font(.timingBoardSmall).monospacedDigits().foregroundStyle(delta < -0.005 ? Theme.green : (delta > 0.005 ? Theme.yellow : Theme.secondaryText))
                    Text(comparison == .routeRecord ? "vs record" : "vs previous").font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            } else {
                Text("No reference").font(.caption2).foregroundStyle(Theme.grey)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour.color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(colour.color.opacity(0.4), lineWidth: 1))
    }
}
