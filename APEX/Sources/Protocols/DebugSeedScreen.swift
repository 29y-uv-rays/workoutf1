import SwiftUI
import SwiftData

#if DEBUG

struct DebugSeedScreen: View {
    @Environment(PersistenceController.self) private var persistence
    @Environment(\.modelContext) private var modelContext
    @State private var status: SeedStatus = .idle
    @State private var count = 0
    @State private var withGPS = 0
    @State private var circuitName = ""
    @State private var creating = false

    enum SeedStatus: Equatable {
        case idle, seeding, done, error(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Debug Seed").font(.title2).foregroundStyle(Theme.text)
                Text("DEBUG ONLY. Seeded data never enters your real workout history.").font(.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.leading).padding(.horizontal)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Loop workouts", systemImage: "figure.run").font(.subheadline).foregroundStyle(Theme.secondaryText)
                    Label("Point-to-point", systemImage: "arrow.right.circle").font(.subheadline).foregroundStyle(Theme.secondaryText)
                    Label("No route (missing GPS)", systemImage: "antenna.radiowaves.left.and.right").font(.subheadline).foregroundStyle(Theme.secondaryText)
                    Label("Large GPS dropout", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Theme.secondaryText)
                    Label("Reverse direction", systemImage: "arrow.left.circle").font(.subheadline).foregroundStyle(Theme.secondaryText)
                    Label("With pauses", systemImage: "pause.circle").font(.subheadline).foregroundStyle(Theme.secondaryText)
                    Label("Too-long (unassigned)", systemImage: "minus.circle").font(.subheadline).foregroundStyle(Theme.secondaryText)
                }
                Divider().background(Theme.border)
                if case .error(let msg) = status {
                    Text(msg).font(.caption).foregroundStyle(.red)
                }
                Button("Seed fixtures") { Task { await seed() } }
                    .buttonStyle(.borderedProminent).tint(Theme.purple).disabled(status == .seeding || creating)
                if status == .done {
                    VStack {
                        Text("Imported \(count) workouts, \(withGPS) with GPS.").foregroundStyle(Theme.text)
                        TextField("Circuit name", text: $circuitName).textFieldStyle(.roundedBorder).foregroundStyle(Theme.text)
                        Button("Create circuit from first loop workout") { creating = true; Task { await createCircuit() } }
                            .buttonStyle(.bordered).tint(Theme.green).disabled(circuitName.isEmpty || creating)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Debug Seed")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @MainActor
    private func seed() async {
        status = .seeding
        do {
            let ctx = persistence.container.mainContext
            // clear prior seeded data
            try? ctx.delete(model: Workout.self)
            try? ctx.delete(model: Circuit.self)
            try? ctx.delete(model: SectorResult.self)
            try? ctx.save()
            let generator = DebugWorkoutSource(seed: 12345)
            for w in generator.asWorkouts {
                let model = Workout(sourceWorkoutUUID: w.sourceWorkoutUUID, activityType: w.activityType, startDate: w.startDate, endDate: w.endDate, durationSeconds: w.durationSeconds, distanceMeters: w.distanceMeters, routeFile: nil, timingStatus: w.hasGPS ? .pending : .missingGPS, lapTimeSeconds: nil, lapColour: nil, circuitVersion: 0, algorithmVersion: TimingEngine.algorithmVersion, circuit: nil)
                ctx.insert(model)
                if w.hasGPS {
                    _ = persistence.fileStore.writeRouteJSON(w.samples)
                }
            }
            try ctx.save()
            count = generator.asWorkouts.count
            withGPS = generator.asWorkouts.filter { $0.hasGPS }.count
            status = .done
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    @MainActor
    private func createCircuit() async {
        guard let first = generator.asWorkouts.first(where: { $0.hasGPS }) else {
            status = .error("No GPS workout to create a circuit from."); return
        }
        creating = true
        guard let routeFile = persistence.fileStore.writeRouteJSON(first.samples) else {
            status = .error("Could not write route file."); creating = false; return
        }
        let totalDist = first.distanceMeters
        let circuit = Circuit(name: circuitName.isEmpty ? "The Park Loop" : circuitName, activityType: first.activityType, geometryFile: routeFile, totalDistanceMeters: totalDist, isLoop: true, originWorkoutUUID: first.sourceWorkoutUUID)
        let ctx = persistence.container.mainContext
        ctx.insert(circuit)
        if let w = try? ctx.fetch(FetchDescriptor<Workout>()).first(where: { $0.sourceWorkoutUUID == first.sourceWorkoutUUID }) {
            w.circuit = circuit
            w.timingStatus = .pending
        }
        try ctx.save()
        let recompute = RecomputeService(container: persistence.container, fileStore: persistence.fileStore)
        await recompute.recomputeAll()
        try ctx.save()
        count = generator.asWorkouts.count
        withGPS = generator.asWorkouts.filter { $0.hasGPS }.count
        status = .done
        creating = false
    }

    private var generator: DebugWorkoutSource { DebugWorkoutSource(seed: 12345) }
}

#endif
