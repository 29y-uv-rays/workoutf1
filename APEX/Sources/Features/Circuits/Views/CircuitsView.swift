import SwiftUI
import SwiftData

struct CircuitsView: View {
    @Environment(PersistenceController.self) private var persistence
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Circuit.name) private var circuits: [Circuit]
    @Query(filter: #Predicate<Workout> { $0.circuit == nil }, sort: \Workout.startDate, order: .reverse) private var unassigned: [Workout]
    @State private var showingCreate = false
    @State private var selectedWorkoutForCreate: Workout?

    var body: some View {
        NavigationStack {
            List {
                if !circuits.isEmpty {
                    Section("Circuits") {
                        ForEach(circuits) { circuit in CircuitRow(circuit: circuit) }
                    }
                }
                if !unassigned.isEmpty {
                    Section("Unassigned routes") {
                        ForEach(unassigned) { w in UnassignedRow(workout: w).onTapGesture { selectedWorkoutForCreate = w; showingCreate = true } }
                    }
                }
                if circuits.isEmpty && unassigned.isEmpty {
                    Section { Text("No circuits yet").foregroundStyle(Theme.secondaryText) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Circuits")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingCreate = true; selectedWorkoutForCreate = unassigned.first } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingCreate) {
                if let w = selectedWorkoutForCreate {
                    CircuitEditorView(workout: w, isPresented: $showingCreate, isNew: true)
                } else {
                    VStack { Text("Select an unassigned workout to create a circuit from it.").foregroundStyle(Theme.secondaryText); Spacer() }
                        .presentationDetents([.medium])
                }
            }
        }
    }
}

struct CircuitRow: View {
    let circuit: Circuit
    @Environment(PersistenceController.self) private var persistence

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(circuit.name).font(.headline).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Text(circuit.activityType.displayName).font(.caption).foregroundStyle(Theme.secondaryText)
                    Text("•").foregroundStyle(Theme.secondaryText)
                    Text(String(format: "%.2f km", circuit.totalDistanceMeters / 1000.0)).font(.caption).foregroundStyle(Theme.secondaryText)
                    Text("v\(circuit.version)").font(.caption2).foregroundStyle(Theme.grey)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(bestLapTime(circuit).map { TimeFormat.absolute($0) } ?? "—").font(.title3).monospacedDigits().foregroundStyle(Theme.text)
                Text("\(lapCount(circuit)) laps").font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 4)
    }

    private func lapCount(_ c: Circuit) -> Int {
        let circuitID = c.id
        let valid = TimingStatus.valid.rawValue
        let desc = FetchDescriptor<Workout>(predicate: #Predicate { $0.circuit?.id == circuitID && $0.timingStatusRaw == valid })
        return (try? persistence.container.mainContext.fetch(desc).count) ?? 0
    }

    private func bestLapTime(_ c: Circuit) -> Double? {
        let circuitID = c.id
        let valid = TimingStatus.valid.rawValue
        let desc = FetchDescriptor<Workout>(predicate: #Predicate { $0.circuit?.id == circuitID && $0.timingStatusRaw == valid && $0.lapTimeSeconds != nil })
        return (try? persistence.container.mainContext.fetch(desc)).flatMap { $0.compactMap(\.lapTimeSeconds).min() }
    }
}

struct UnassignedRow: View {
    let workout: Workout
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(workout.activityType.displayName).font(.subheadline).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Text(workout.startDate.formatted(.dateTime.day().month().year())).font(.caption).foregroundStyle(Theme.secondaryText)
                    Text("•").foregroundStyle(Theme.secondaryText)
                    Text(String(format: "%.2f km", workout.distanceMeters / 1000.0)).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                if workout.routeFile == nil { Text("No GPS route").font(.caption2).foregroundStyle(Theme.grey) }
            }
            Spacer()
            Image(systemName: "plus.circle").foregroundStyle(Theme.purple)
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
extension CircuitsView {
    static func route(for workout: Workout, persistence: PersistenceController) -> [MapPoint]? {
        persistence.fileStore.loadRouteJSON(for: workout.sourceWorkoutUUID)
    }
}
#endif
