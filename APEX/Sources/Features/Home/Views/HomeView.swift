import SwiftUI
import SwiftData
import MapKit

struct HomeView: View {
    @Environment(PersistenceController.self) private var persistence
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workout.startDate, order: .reverse) private var workouts: [Workout]
    @Query(filter: #Predicate<AppStateModel> { _ in true }) private var appStateRows: [AppStateModel]
    @State private var settingsOpen = false
    @State private var isRefreshing = false
    @State private var lastSyncText = "Not yet synced"
    @State private var syncError: String?

    private var latestWorkout: Workout? { workouts.first }
    private var appState: AppStateModel { appStateRows.first ?? AppStateModel() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerSection
                    if let w = latestWorkout {
                        if w.timingStatus == .valid {
                            latestSessionCard(w)
                            raceEngineerCard(for: w)
                        } else {
                            latestSessionCardNoTelemetry(w)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("APEX")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { settingsOpen = true } label: { Image(systemName: "gearshape.fill").foregroundStyle(Theme.text) } }
                ToolbarItem(placement: .topBarLeading) { SyncStatusButton(isRefreshing: $isRefreshing) { Task { await sync() } } }
            }
            .sheet(isPresented: $settingsOpen) { SettingsView(isPresented: $settingsOpen) }
            .refreshable { await sync() }
            .overlay(alignment: .bottom) {
                if let err = syncError {
                    Text(err).font(.caption).foregroundStyle(.red).padding()
                }
            }
        }
        .onAppear {
            refreshSyncText()
            // Auto-sync on launch, at most once every five minutes.
            if appState.autoSync {
                let last = appState.lastSyncDate ?? .distantPast
                if Date().timeIntervalSince(last) > 300 { Task { await sync() } }
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting).font(.title2).fontWeight(.semibold).foregroundStyle(Theme.text)
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day(.twoDigits))).font(.subheadline).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 6) {
                Circle().fill(syncStatusColor).frame(width: 7, height: 7)
                Text(lastSyncText).font(.caption).foregroundStyle(Theme.secondaryText)
                if isRefreshing { ProgressView().scaleEffect(0.7) }
            }
            .monospacedDigits()
        }
        .padding(.top, 4)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var syncStatusColor: Color {
        if isRefreshing { return Theme.yellow }
        if syncError != nil { return .red }
        return Theme.green
    }

    private func refreshSyncText() {
        if let last = appState.lastSyncDate {
            let interval = Date().timeIntervalSince(last)
            if interval < 60 { lastSyncText = "Last synced just now" }
            else if interval < 3600 { lastSyncText = "Last synced \(Int(interval/60)) min ago" }
            else if interval < 86400 { lastSyncText = "Last synced \(Int(interval/3600)) hr ago" }
            else { lastSyncText = "Last synced \(Int(interval/86400)) day ago" }
        } else {
            lastSyncText = "Not yet synced"
        }
    }

    // MARK: - Latest session card

    private func latestSessionCard(_ w: Workout) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.circuit?.name ?? "Unknown circuit").font(.subheadline).fontWeight(.semibold).foregroundStyle(Theme.text)
                        Text("\(w.activityType.displayName) • \(distanceLabel(w))").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("LAP").font(.caption2).foregroundStyle(Theme.secondaryText).tracking(1)
                        Text(TimeFormat.absolute(w.lapTimeSeconds ?? 0)).font(.title).fontWeight(.semibold).monospacedDigits().foregroundStyle(Theme.text)
                    }
                }
                if let route = persistence.fileStore.loadRouteJSON(for: w.sourceWorkoutUUID), let circuit = w.circuit, circuit.isLoop {
                    miniMapRoute(route, circuit: circuit).frame(height: 90).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface).frame(height: 90).overlay(VStack(spacing: 4) { Image(systemName: "map").foregroundStyle(Theme.secondaryText); Text("No route map").font(.caption2).foregroundStyle(Theme.secondaryText) })
                }
                HStack(spacing: 8) {
                    ForEach(1...3, id: \.self) { idx in sectorChip(for: w, sectorIndex: idx, label: "S\(idx)") }
                }
            }
        }
    }

    private func latestSessionCardNoTelemetry(_ w: Workout) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.circuit?.name ?? "Unknown circuit").font(.subheadline).fontWeight(.semibold).foregroundStyle(Theme.text)
                        Text("\(w.activityType.displayName) • \(distanceLabel(w))").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("LAP").font(.caption2).foregroundStyle(Theme.secondaryText).tracking(1)
                        Text(noTelemetryLabel(w)).font(.title3).fontWeight(.medium).monospacedDigits().foregroundStyle(Theme.grey)
                    }
                }
                Text(timingStatusExplanation(w.timingStatus)).font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func distanceLabel(_ w: Workout) -> String {
        guard w.distanceMeters > 0 else { return "—" }
        return String(format: "%.2f km", w.distanceMeters / 1000.0)
    }

    private func sectorChip(for w: Workout, sectorIndex: Int, label: String) -> some View {
        let r = sectorResult(for: w, sectorIndex: sectorIndex)
        let col = (r?.colour ?? .grey)
        let time = r?.durationSeconds.map(TimeFormat.absolute) ?? "—"
        return HStack(spacing: 5) {
            Text(col.legendGlyph).font(.system(size: 10, weight: .bold, design: .default)).foregroundStyle(col.color)
            Text(label).font(.caption2).foregroundStyle(Theme.secondaryText)
            Text(time).font(.caption).monospacedDigits().foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(col.color.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityLabel("Sector \(sectorIndex), \(col.accessibilityLabel), \(time)")
    }

    private func noTelemetryLabel(_ w: Workout) -> String {
        switch w.timingStatus {
        case .missingGPS: return "NO TELEMETRY"
        case .partial: return "PARTIAL"
        case .unmatched: return "UNMATCHED"
        case .pending: return "PENDING"
        case .valid: return "—"
        case .needsCircuitChoice: return "CHOOSE"
        }
    }

    private func timingStatusExplanation(_ s: TimingStatus) -> String {
        switch s {
        case .missingGPS: return "No GPS route was recorded for this workout."
        case .partial: return "GPS was incomplete; no full lap time is available."
        case .unmatched: return "This route doesn't match any saved circuit yet."
        case .pending: return "Timing is not yet computed."
        case .valid: return ""
        case .needsCircuitChoice: return "This workout could match more than one circuit."
        }
    }

    private func sectorResult(for w: Workout, sectorIndex: Int) -> SectorResult? {
        let desc = FetchDescriptor<SectorResult>(
            predicate: #Predicate { sectorResult in
                sectorResult.workouUUID == w.sourceWorkoutUUID &&
                sectorResult.sectorIndex == sectorIndex
            }
        )
        return (try? modelContext.fetch(desc)).flatMap { $0.first }
    }

    // MARK: - Mini map

    private func miniMapRoute(_ samples: [MapPoint], circuit: Circuit) -> some View {
        Map {
            if !samples.isEmpty {
                let first = samples.first!, last = samples.last!
                Annotation("S/F", coordinate: CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon)) { Image(systemName: "flag.fill").foregroundStyle(Theme.purple) }
                Annotation("A", coordinate: circuit.boundaryCoordinate(at: 1.0/3.0, points: samples)) { Image(systemName: "mappin.circle.fill").foregroundStyle(Theme.green) }
                Annotation("B", coordinate: circuit.boundaryCoordinate(at: 2.0/3.0, points: samples)) { Image(systemName: "mappin.circle.fill").foregroundStyle(Theme.yellow) }
                ForEach(1...3, id: \.self) { idx in
                    let slice = sectorSlice(samples: samples, sectorIndex: idx, circuit: circuit)
                    if slice.count > 1 { MapPolyline(coordinates: slice).stroke(sectorMapColor(for: idx), lineWidth: 3) }
                }
                MapPolyline(coordinates: samples.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }).stroke(Theme.mapRouteLine, lineWidth: 2)
            }
        }
        .mapStyle(.standard)
        .mapRotationTap(false)
    }

    private func sectorSlice(samples: [MapPoint], sectorIndex: Int, circuit: Circuit) -> [CLLocationCoordinate2D] {
        guard let def = circuit.sectorDefinition(at: sectorIndex), def.startDistanceMeters < def.endDistanceMeters else { return [] }
        return samples.enumerated().compactMap { (i, p) in
            let d = Double(i) / Double(max(1, samples.count - 1)) * circuit.totalDistanceMeters
            if d >= def.startDistanceMeters && d <= def.endDistanceMeters { return CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }
            return nil
        }
    }

    private func sectorMapColor(for idx: Int) -> Color {
        switch idx {
        case 1: return SectorColor.purple.color
        case 2: return SectorColor.green.color
        case 3: return SectorColor.yellow.color
        default: return Theme.grey
        }
    }

    // MARK: - Race engineer card

    private func raceEngineerCard(for w: Workout) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("RACE ENGINEER").font(.labelCaps).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    if debrief(for: w) != nil { Text("Cached").font(.caption).foregroundStyle(Theme.secondaryText) }
                }
                if let debrief = debrief(for: w), let payload = debrief.payload() {
                    Text(payload.headline).font(.subheadline).fontWeight(.medium).foregroundStyle(Theme.text).lineLimit(2)
                    Text(payload.summary).font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(4)
                    if !payload.sectorNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(payload.sectorNotes.enumerated()), id: \.element.sector) { _, note in Text(note.note).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2) }
                        }
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            sendPreviewBlock(for: w)
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
                        if KeychainService.shared.hasGeminiKey { Task { await requestRaceEngineer(for: w) } } else { settingsOpen = true }
                    } label: {
                        Label("Ask your Race Engineer", systemImage: "mic.fill").font(.subheadline).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.purple).controlSize(.large).disabled(!KeychainService.shared.hasGeminiKey)
                }
            }
        }
    }

    private func sendPreviewBlock(for w: Workout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This lap sends only:").font(.caption).fontWeight(.semibold).foregroundStyle(Theme.secondaryText.opacity(0.8))
            Text(buildSendPreview(w)).font(.caption).foregroundStyle(Theme.text).lineLimit(6)
        }
    }

    private func buildSendPreview(_ w: Workout) -> String {
        var parts = ["Circuit: \(w.circuit?.name ?? "—")", "Activity: \(w.activityType.displayName)", "Date: \(w.startDate.formatted(.dateTime.day().month().year()))"]
        if let lt = w.lapTimeSeconds { parts.append("Lap: \(TimeFormat.absolute(lt))") } else { parts.append("Lap: —") }
        if let circuit = w.circuit {
            for idx in 1...3 {
                if let r = sectorResult(for: w, sectorIndex: idx) { parts.append("S\(idx): \(TimeFormat.absolute(r.durationSeconds ?? 0))") } else { parts.append("S\(idx): —") }
            }
        }
        parts.append("No coordinates, no raw GPS, no names.")
        return parts.joined(separator: " • ")
    }

    private func debrief(for w: Workout) -> RaceEngineerDebrief? {
        let desc = FetchDescriptor<RaceEngineerDebrief>(
            predicate: #Predicate { debrief in
                debrief.workouUUID == w.sourceWorkoutUUID
            }
        )
        return (try? modelContext.fetch(desc)).flatMap { $0.first }
    }

    @MainActor
    private func requestRaceEngineer(for w: Workout) async {
        guard KeychainService.shared.hasGeminiKey else { return }
        let available = await RaceEngineer.requestDebrief(for: w, modelContext: modelContext)
        if available { Haptics.light() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Panel {
            VStack(spacing: 12) {
                Image(systemName: "figure.run.circle").font(.system(size: 44)).foregroundStyle(Theme.secondaryText.opacity(0.6))
                Text("No workouts yet").font(.headline).foregroundStyle(Theme.text)
                Text("Your runs, walks and rides from Apple Health will appear here after you import them.").font(.subheadline).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                Button("Import from Health") { settingsOpen = true }.buttonStyle(.borderedProminent).tint(Theme.purple)
            }
        }
    }

    // MARK: - Sync

    @MainActor
    private func sync() async {
        isRefreshing = true
        syncError = nil
        let result = await HealthKitOnboarding.importAndPersist(
            since: appState.lastSyncDate,
            modelContext: modelContext,
            fileStore: persistence.fileStore
        )
        if let message = result.error {
            syncError = message
        } else {
            appState.lastSyncDate = Date()
            try? modelContext.save()
            refreshSyncText()
            Haptics.light() // sync completed
        }
        isRefreshing = false
    }
}

// MARK: - Sync status button

struct SyncStatusButton: View {
    @Binding var isRefreshing: Bool
    let action: () async -> Void
    var body: some View {
        Button { Task { await action() } } label: {
            HStack(spacing: 4) { if isRefreshing { ProgressView().scaleEffect(0.7) } else { Image(systemName: "arrow.triangle.2.circlepath") } }
                .font(.caption).foregroundStyle(Theme.text)
        }
    }
}
