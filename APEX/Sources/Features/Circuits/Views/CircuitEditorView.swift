import SwiftUI
import MapKit
import SwiftData

struct CircuitEditorView: View {
    let workout: Workout
    @Binding var isPresented: Bool
    let isNew: Bool

    @Environment(PersistenceController.self) private var persistence
    @Environment(\.modelContext) private var modelContext
    @State private var circuitName: String
    @State private var fracA: Double = 1.0/3.0
    @State private var fracB: Double = 2.0/3.0
    @State private var saving = false
    @State private var showReanalyse = false
    @State private var savingError: String?

    private var samples: [MapPoint] { persistence.fileStore.loadRouteJSON(for: workout.sourceWorkoutUUID) ?? [] }
    private var totalDist: Double { workout.distanceMeters }
    private var activityType: ActivityType { workout.activityType }

    init(workout: Workout, isPresented: Binding<Bool>, isNew: Bool) {
        self.workout = workout
        self._isPresented = isPresented
        self.isNew = isNew
        self._circuitName = State(initialValue: "The Park Loop")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sectorMap.frame(height: 380).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))

                VStack(spacing: 16) {
                    boundarySlider(label: "Boundary A (S1/S2)", fraction: $fracA, colour: SectorColor.green.color, distance: distanceFor(fracA))
                    boundarySlider(label: "Boundary B (S2/S3)", fraction: $fracB, colour: SectorColor.yellow.color, distance: distanceFor(fracB))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("SECTORS").font(.labelCaps).foregroundStyle(Theme.secondaryText)
                        HStack(spacing: 8) {
                            ForEach(1...3, id: \.self) { idx in sectorInfo(idx) }
                        }
                        if let err = validationMessage {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)

                    HStack {
                        Button("Cancel") { isPresented = false }.buttonStyle(.bordered).tint(Theme.text).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Save circuit") { Task { await save() } }.buttonStyle(.borderedProminent).tint(Theme.purple).disabled(saving || fracA <= 0 || fracB <= fracA || fracB >= 1)
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle(isNew ? "Create circuit" : "Edit circuit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { isPresented = false } } }
            .alert("Reanalyse laps?", isPresented: $showReanalyse) {
                Button("Reanalyse") { Task { await reanalyse() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saving created circuit version \(newVersion). Reanalyse the laps with this version now, or later from the Circuits list.")
            }
            .alert("Save error", isPresented: .constant(savingError != nil)) {
                Button("OK", role: .cancel) { savingError = nil }
            } message: {
                Text(savingError ?? "")
            }
        }
    }

    // MARK: - Map

    private var sectorMap: some View {
        Group {
            if samples.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface)
                    VStack(spacing: 6) {
                        Image(systemName: "map").font(.title2).foregroundStyle(Theme.secondaryText)
                        Text("No route").font(.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                }
            } else {
                Map {
                    let first = samples.first!
                    Annotation("S/F", coordinate: CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon)) { Image(systemName: "flag.fill").foregroundStyle(Theme.purple).font(.title3) }
                    Annotation("A", coordinate: coordinateForFraction(fracA)) { Image(systemName: "mappin.circle.fill").foregroundStyle(SectorColor.green.color).font(.title3) }
                    Annotation("B", coordinate: coordinateForFraction(fracB)) { Image(systemName: "mappin.circle.fill").foregroundStyle(SectorColor.yellow.color).font(.title3) }
                    ForEach(1...3, id: \.self) { idx in
                        let slice = sectorSlice(for: idx)
                        if slice.count > 1 { MapPolyline(coordinates: slice).stroke(sectorColor(for: idx), lineWidth: 4) }
                    }
                    if samples.count > 1 { MapPolyline(coordinates: samples.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }).stroke(Theme.mapRouteLine.opacity(0.5), lineWidth: 2) }
                }
                .mapStyle(.standard)
            }
        }
    }

    private func sectorSlice(for idx: Int) -> [CLLocationCoordinate2D] {
        guard let def = sectorDefinition(for: idx) else { return [] }
        return samples.enumerated().compactMap { (i, p) in
            let d = Double(i) / Double(max(1, samples.count - 1)) * totalDist
            if d >= def.startDistanceMeters && d <= def.endDistanceMeters { return CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }
            return nil
        }
    }

    private func sectorColor(for idx: Int) -> Color {
        switch idx {
        case 1: return SectorColor.purple.color
        case 2: return SectorColor.green.color
        case 3: return SectorColor.yellow.color
        default: return Theme.grey
        }
    }

    private func sectorDefinition(for idx: Int) -> SectorDefForEngine? {
        switch idx {
        case 1: return SectorDefForEngine(index: 1, startDistanceMeters: 0, endDistanceMeters: distanceFor(fracA))
        case 2: return SectorDefForEngine(index: 2, startDistanceMeters: distanceFor(fracA), endDistanceMeters: distanceFor(fracB))
        case 3: return SectorDefForEngine(index: 3, startDistanceMeters: distanceFor(fracB), endDistanceMeters: totalDist)
        default: return nil
        }
    }

    // MARK: - Slider

    private func boundarySlider(label: String, fraction: Binding<Double>, colour: Color, distance: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.labelCaps).foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(String(format: "%.0f%%  •  %.0f m", fraction.wrappedValue * 100, distance)).font(.timingBoardSmall).monospacedDigits().foregroundStyle(colour)
            }
            HStack {
                Text("0%").font(.caption2).foregroundStyle(Theme.secondaryText)
                Slider(value: fraction, in: 0...1, step: 0.001).tint(colour).background(Theme.surface)
                Text("100%").font(.caption2).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func distanceFor(_ frac: Double) -> Double { frac * totalDist }
    private func coordinateForFraction(_ frac: Double) -> CLLocationCoordinate2D {
        let idx = Int(frac * Double(samples.count - 1)).clamped(to: 0...(samples.count - 1))
        return CLLocationCoordinate2D(latitude: samples[idx].lat, longitude: samples[idx].lon)
    }

    // MARK: - Validation

    private var validationMessage: String? {
        let a = fracA, b = fracB
        if b <= a + 0.001 { return "Boundary A must be before Boundary B." }
        let minM = totalDist * 0.05
        if (distanceFor(a) - 0) < minM { return "Sector 1 is shorter than 5% of the route." }
        if (distanceFor(b) - distanceFor(a)) < minM { return "Sector 2 is shorter than 5% of the route." }
        if (totalDist - distanceFor(b)) < minM { return "Sector 3 is shorter than 5% of the route." }
        return nil
    }

    private func sectorInfo(_ idx: Int) -> some View {
        let start = idx == 1 ? 0.0 : (idx == 2 ? distanceFor(fracA) : distanceFor(fracB))
        let end = idx == 1 ? distanceFor(fracA) : (idx == 2 ? distanceFor(fracB) : totalDist)
        let len = end - start
        return HStack(spacing: 8) {
            Text("S\(idx)").font(.caption).foregroundStyle(sectorColor(for: idx))
            Text(String(format: "%.0f m", len)).font(.caption).monospacedDigits().foregroundStyle(Theme.text)
        }
    }

    // MARK: - Save

    private var newVersion: Int { (workout.circuit?.version ?? 0) + 1 }

    @MainActor
    private func save() async {
        guard validationMessage == nil else { return }
        saving = true
        defer { saving = false }
        do {
            let geometryFile: String
            if let existing = workout.circuit {
                geometryFile = existing.geometryFile
            } else {
                guard let routeSamples = persistence.fileStore.loadRouteSamples(for: workout.sourceWorkoutUUID) else {
                    savingError = "No route samples found."
                    return
                }
                guard let written = persistence.fileStore.writeCircuitPolyline(
                    routeSamples.map { (lat: $0.lat, lon: $0.lon) },
                    distanceMeters: totalDist,
                    activityType: activityType,
                    isLoop: true
                ) else {
                    savingError = "Could not write circuit geometry file."
                    return
                }
                geometryFile = written
            }
            let circuit = Circuit(name: circuitName, activityType: activityType, geometryFile: geometryFile, totalDistanceMeters: totalDist, isLoop: true, originWorkoutUUID: workout.sourceWorkoutUUID, sectors: [SectorDefinition(index: 1, startDistanceMeters: 0, endDistanceMeters: distanceFor(fracA)), SectorDefinition(index: 2, startDistanceMeters: distanceFor(fracA), endDistanceMeters: distanceFor(fracB)), SectorDefinition(index: 3, startDistanceMeters: distanceFor(fracB), endDistanceMeters: totalDist)], version: newVersion)
            let ctx = persistence.container.mainContext
            ctx.insert(circuit)
            if var w = try? ctx.fetch(FetchDescriptor<Workout>()).first(where: { $0.sourceWorkoutUUID == workout.sourceWorkoutUUID }) {
                w.circuit = circuit
                w.timingStatus = .pending
                w.lapTimeSeconds = nil
                w.lapColour = nil
                w.circuitVersion = newVersion
            }
            try ctx.save()
            let recompute = RecomputeService(container: persistence.container, fileStore: persistence.fileStore)
            await recompute.recomputeAll()
            try ctx.save()
            savingError = nil
            showReanalyse = true
            isPresented = false
        } catch {
            savingError = error.localizedDescription
        }
    }

    @MainActor
    private func reanalyse() async {
        let recompute = RecomputeService(container: persistence.container, fileStore: persistence.fileStore)
        await recompute.reanalyseAll()
        try? persistence.container.mainContext.save()
        showReanalyse = false
    }
}
