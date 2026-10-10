import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(PersistenceController.self) private var persistence
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<AppStateModel> { _ in true }, limit: 1) private var appStateRows: [AppStateModel]
    @State private var step: Step = .welcome
    @State private var authResult: HealthKitAccessResult = .notAvailable
    @State private var importPhase: ImportPhase = .idle
    @State private var importedCount = 0
    @State private var withGPSCount = 0
    @State private var error: String?

    enum Step { case welcome, auth, importing, result }
    enum ImportPhase { case idle, starting, inProgress(batchIndex: Int, total: Int?), done(imported: Int, withGPS: Int), empty(reason: String), error(String) }

    var body: some View {
        VStack(spacing: 0) {
            progressIndicator
            switch step {
            case .welcome: welcomeStep
            case .auth: authStep
            case .importing: importingStep
            case .result: resultStep
            }
        }
        .background(Theme.background)
        .animation(.easeInOut, value: step)
    }

    private var progressIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in Capsule().fill(stepIndex >= i ? Color.white : Theme.border).frame(height: 4) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    private var stepIndex: Int {
        switch step {
        case .welcome: 0
        case .auth: 1
        case .importing: 2
        case .result: 3
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 56)).foregroundStyle(Theme.purple)
                Text("Your route. Your record. Your race.").font(.title2).fontWeight(.semibold).foregroundStyle(Theme.text)
                Text("APEX turns your completed runs, walks and rides from Apple Health into Formula 1-style timing sessions.").font(.body).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center).padding(.horizontal, 24)
                Text("It reads Apple Health and never records GPS or writes to Health.").font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button("Continue") { step = .auth }.buttonStyle(.borderedProminent).tint(Theme.purple).padding(.bottom, 32)
        }
    }

    // MARK: - Auth

    private var authStep: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "heart.text.square").font(.system(size: 48)).foregroundStyle(Theme.purple)
                Text("Connect Apple Health").font(.title2).fontWeight(.semibold).foregroundStyle(Theme.text)
                Text("APEX needs read access to your workouts and workout routes so it can time laps on your regular routes.").font(.body).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center).padding(.horizontal, 24)
                Text("APEX never writes to Health and never records GPS.").font(.subheadline).foregroundStyle(Theme.grey)
            }
            Spacer()
            Button("Request HealthKit access") { Task { await requestHealthKit() } }.buttonStyle(.borderedProminent).tint(Theme.purple).padding(.bottom, 32)
            if let err = error { Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal) }
        }
    }

    // MARK: - Importing

    private var importingStep: some View {
        VStack(spacing: 20) {
            Spacer()
            VStack(spacing: 12) {
                if case .done(let imp, let gps) = importPhase {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(Theme.green)
                    Text("Import complete").font(.headline).foregroundStyle(Theme.text)
                    Text("\(imp) workouts imported, \(gps) with GPS.").font(.subheadline).foregroundStyle(Theme.secondaryText)
                    if gps == 0 {
                        Text("No workouts had a GPS route. APEX needs routes to time laps.").font(.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                    }
                } else if case .empty = importPhase {
                    Text("No workouts found. APEX reads Apple Health; if you record workouts elsewhere, they will appear here after you record one with a route.").font(.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                } else if case .error(let msg) = importPhase {
                    Text(msg).font(.caption).foregroundStyle(.red)
                } else {
                    ProgressView().scaleEffect(1.2).tint(Theme.purple)
                    Text("Importing workouts from Apple Health…").font(.headline).foregroundStyle(Theme.text)
                    Text("\(importedCount) imported, \(withGPSCount) with GPS").font(.subheadline).foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            if isImportFinished {
                Button("Continue") { completeOnboarding() }.buttonStyle(.borderedProminent).tint(Theme.purple).padding(.bottom, 32)
            } else if case .error = importPhase {
                Button("Retry") { Task { await runImport() } }.buttonStyle(.borderedProminent).tint(Theme.purple).padding(.bottom, 32)
            } else {
                Button("Back") { step = .welcome }.buttonStyle(.bordered).tint(Theme.text).padding(.bottom, 32)
            }
        }
    }

    // MARK: - Result

    private var resultStep: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: withGPSCount > 0 ? "figure.run.circle.fill" : "antenna.radiowaves.left.and.right").font(.system(size: withGPSCount > 0 ? 56 : 48)).foregroundStyle(withGPSCount > 0 ? Theme.green : Theme.secondaryText)
                Text(withGPSCount > 0 ? "Ready to race" : "Some setup needed").font(.title2).fontWeight(.semibold).foregroundStyle(Theme.text)
                if withGPSCount > 0 {
                    Text("\(importedCount) workouts imported, \(withGPSCount) with GPS routes.").font(.body).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                } else {
                    Text("No workouts with GPS routes were found in Apple Health.").font(.body).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Why you might see this").font(.subheadline).fontWeight(.semibold).foregroundStyle(Theme.text)
                        Text("• Your workouts were recorded indoors or with GPS off.")
                        Text("• The app that recorded them did not save a route.")
                        Text("• Apple Health read access wasn't granted.")
                        Text("APEX can still time laps once a workout with a route is recorded.").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.horizontal, 24)
                }
            }
            Spacer()
            Button("Continue to APEX") { completeOnboarding() }.buttonStyle(.borderedProminent).tint(Theme.purple).padding(.bottom, 32)
            Button("Open Settings") { step = .welcome }.buttonStyle(.bordered).tint(Theme.text).padding(.bottom, 12)
        }
    }

    // MARK: - Actions

    @MainActor
    private func requestHealthKit() async {
        error = nil
        authResult = await HealthKitOnboarding.requestAccess()
        switch authResult {
        case .authorised, .authorisedWithLimitedData: step = .importing; await runImport()
        case .denied, .notAvailable: error = "HealthKit access is required. Open Settings and enable APEX access to workouts."
        case .error(let msg): error = msg
        }
    }

    @MainActor
    private func runImport() async {
        importPhase = .starting
        importedCount = 0
        withGPSCount = 0
        let result = await HealthKitOnboarding.importAndPersist(since: nil, modelContext: modelContext, fileStore: persistence.fileStore)
        if let message = result.error {
            error = message
            importPhase = .error(message)
        } else if result.importedCount == 0 {
            importPhase = .empty(reason: "No workouts were found in Apple Health.")
        } else {
            importedCount = result.importedCount
            withGPSCount = result.withGPSCount
            importPhase = .done(imported: result.importedCount, withGPS: result.withGPSCount)
        }
        if isImportFinished { step = .result }
    }

    private var isImportFinished: Bool {
        if case .done = importPhase { return true }
        if case .empty = importPhase { return true }
        return false
    }

    private func completeOnboarding() {
        if let row = appStateRows.first {
            row.onboardingComplete = true
            try? modelContext.save()
        }
    }
}
