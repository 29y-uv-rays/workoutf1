import SwiftUI
import SwiftData

struct LapsView: View {
    @Environment(PersistenceController.self) private var persistence
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workout.startDate, order: .reverse) private var workouts: [Workout]
    @Query(sort: \Circuit.name) private var circuits: [Circuit]
    @State private var filterCircuitID: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Circuit", selection: $filterCircuitID) {
                    Text("All").tag(nil as UUID?)
                    ForEach(circuits) { c in Text(c.name).tag(c.id as UUID?) }
                }
                .pickerStyle(.menu)
                .tint(Theme.text)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if displayedWorkouts.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(displayedWorkouts) { w in LapRow(workout: w) }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(Theme.background)
                }
            }
            .background(Theme.background)
            .navigationTitle("Laps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All circuits") { filterCircuitID = nil }
                        Divider()
                        ForEach(circuits) { c in Button(c.name) { filterCircuitID = c.id } }
                    } label: {
                        HStack(spacing: 4) { Text(filterLabel).font(.caption); Image(systemName: "line.3.horizontal.decrease.circle").font(.caption) }
                            .foregroundStyle(Theme.text)
                    }
                }
            }
        }
    }

    private var filterLabel: String {
        if let id = filterCircuitID, let c = circuits.first(where: { $0.id == id }) { return c.name }
        return "All"
    }

    private var displayedWorkouts: [Workout] {
        let visible = workouts.filter { w in
            switch w.timingStatus {
            case .valid, .partial, .missingGPS:
                return true
            case .unmatched:
                return w.circuit != nil // assigned, but the route did not line up with the circuit
            case .pending, .needsCircuitChoice:
                return false
            }
        }
        if let id = filterCircuitID { return visible.filter { $0.circuit?.id == id } }
        return visible
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "timer").font(.system(size: 40)).foregroundStyle(Theme.secondaryText.opacity(0.6))
            Text("No laps").font(.headline).foregroundStyle(Theme.text)
            Text("Completed workouts matched to a circuit will appear here.").font(.subheadline).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }
}

struct LapRow: View {
    let workout: Workout
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.activityType.displayName).font(.caption).foregroundStyle(Theme.secondaryText)
                Text(workout.startDate.formatted(date: .numeric, time: .omitted)).font(.subheadline).foregroundStyle(Theme.text)
            }
            .frame(width: 60, alignment: .leading)

            if let circuit = workout.circuit {
                Text(circuit.name).font(.subheadline).foregroundStyle(Theme.text).lineLimit(1)
            } else {
                Text("Unassigned").font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(1...3, id: \.self) { idx in pip(for: idx) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))

            VStack(alignment: .trailing, spacing: 2) {
                if let lt = workout.lapTimeSeconds {
                    Text(TimeFormat.absolute(lt)).font(.title3).monospacedDigits().foregroundStyle(Theme.text)
                } else {
                    Text(statusBadgeText).font(.caption).fontWeight(.medium).foregroundStyle(Theme.grey)
                }
                if let c = workout.lapColour {
                    Text(c.legendGlyph).font(.system(size: 9, weight: .bold)).foregroundStyle(c.color).accessibilityLabel(c.accessibilityLabel)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func pip(for sectorIndex: Int) -> some View {
        let r = sectorResult(for: sectorIndex)
        let col = (r?.colour ?? .grey)
        if let d = r?.durationSeconds {
            return AnyView(HStack(spacing: 2) { Text(col.legendGlyph).font(.system(size: 8, weight: .bold)).foregroundStyle(col.color); Text(TimeFormat.totalSeconds(d)).font(.caption2).monospacedDigits().foregroundStyle(col.color) }.accessibilityLabel("Sector \(sectorIndex), \(col.accessibilityLabel), \(TimeFormat.totalSeconds(d))"))
        } else {
            return AnyView(Circle().fill(Theme.grey.opacity(0.3)).frame(width: 12, height: 12))
        }
    }

    private var statusBadgeText: String {
        switch workout.timingStatus {
        case .missingGPS: return "NO TELEMETRY"
        case .partial: return "PARTIAL"
        case .unmatched: return "NO MATCH"
        case .pending: return "—"
        case .valid: return "—"
        case .needsCircuitChoice: return "CHOOSE"
        }
    }

    private func sectorResult(for sectorIndex: Int) -> SectorResult? {
        let desc = FetchDescriptor<SectorResult>(
            predicate: #Predicate { sectorResult in
                sectorResult.workouUUID == workout.sourceWorkoutUUID &&
                sectorResult.sectorIndex == sectorIndex
            }
        )
        return (try? modelContext.fetch(desc)).flatMap { $0.first }
    }
}
