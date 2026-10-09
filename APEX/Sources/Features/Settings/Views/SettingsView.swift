import SwiftUI
import SwiftData

struct SettingsView: View {
    @Binding var isPresented: Bool
    @Environment(PersistenceController.self) private var persistence
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<AppStateModel> { _ in true }, limit: 1) private var appStateRows: [AppStateModel]
    @State private var viewModel: SettingsViewModel?

    var body: some View {
        NavigationStack {
            List {
                healthKitSection
                geminiSection
                syncSection
                dataSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { isPresented = false } } }
            .task { viewModel = SettingsViewModel(appState: appStateRows.first ?? AppStateModel(), modelContext: modelContext, persistence: persistence) }
            .alert("Delete all APEX data?", isPresented: .constant(viewModel?.showDeleteConfirmation == true)) {
                Button("Cancel", role: .cancel) { viewModel?.showDeleteConfirmation = false }
                Button("Delete", role: .destructive) { Task { await viewModel?.performDeleteAll() } }
            } message: {
                Text("Removes all APEX data (workouts, circuits, laps, debriefs, files in Application Support) and resets onboarding. Does not touch Apple Health. Gemini API key in Keychain can also be removed.")
            }
        }
    }

    private var healthKitSection: some View {
        Section {
            if let hks = viewModel?.healthKitStatus {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HealthKit").font(.headline).foregroundStyle(Theme.text)
                        Text(hks.text).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    HStack(spacing: 4) { Circle().fill(hks.kind.color).frame(width: 8, height: 8); Text(hks.kind.label).font(.caption).foregroundStyle(Theme.text) }
                }
                if hks.showMissingGPSGuide {
                    Button { /* show guide inline */ } label: { Label("Missing GPS troubleshooting", systemImage: "exclamationmark.triangle") }.foregroundStyle(Theme.text)
                }
                if hks.needsAuth {
                    Button("Open Health Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.foregroundStyle(Theme.text)
                }
                if hks.allowedSync && !hks.isSyncing {
                    Button { Task { await viewModel?.manualSync() } } label: { if hks.isSyncing { ProgressView() } else { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") } }.foregroundStyle(Theme.text)
                }
            } else {
                HStack { Text("HealthKit").foregroundStyle(Theme.secondaryText); Spacer(); Text("Unavailable").foregroundStyle(Theme.grey) }
            }
        } header: { Text("Health") }
    }

    private var geminiSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gemini API key").font(.subheadline).foregroundStyle(Theme.text)
                Text("Stored in the Keychain. APEX never writes it anywhere else.").font(.caption).foregroundStyle(Theme.secondaryText)
                HStack {
                    if KeychainService.shared.hasGeminiKey {
                        SecureField("API key", text: Binding(get: { KeychainService.shared.geminiKey ?? "" }, set: { KeychainService.shared.setGeminiKey($0) })).textFieldStyle(.roundedBorder).foregroundStyle(Theme.text)
                    } else {
                        SecureField("Paste your API key", text: Binding(get: { "" }, set: { KeychainService.shared.setGeminiKey($0) })).textFieldStyle(.roundedBorder).foregroundStyle(Theme.text)
                    }
                    Button { Task { await viewModel?.validateGeminiKey() } } label: { if viewModel?.keyValidating == true { ProgressView() } else { Image(systemName: "checkmark.circle") } }.disabled(KeychainService.shared.geminiKey?.isEmpty ?? true || viewModel?.keyValidating == true).foregroundStyle(Theme.text)
                }
                if let keyStatus = viewModel?.keyStatus {
                    HStack { Circle().fill(keyStatus.color).frame(width: 8, height: 8); Text(keyStatus.label).font(.caption).foregroundStyle(keyStatus.color) }
                }
                Divider().background(Theme.border)
                HStack {
                    Text("Model ID").font(.subheadline).foregroundStyle(Theme.text)
                    Spacer()
                    TextField("Model ID", text: Binding(get: { KeychainService.shared.geminiModelID ?? GeminiService.defaultModelID }, set: { KeychainService.shared.setGeminiModelID($0) })).textFieldStyle(.roundedBorder).font(.caption.monospacedDigit()).foregroundStyle(Theme.text).frame(width: 180)
                }
                DisclosureGroup {
                    Text("The app sends only aggregated lap and sector numbers to Gemini, never raw GPS or coordinates.").font(.caption).foregroundStyle(Theme.secondaryText)
                    Text("A key stored on this device can be extracted by a determined user of this device. For a private single-user app this is accepted.").font(.caption).foregroundStyle(Theme.secondaryText)
                } label: {
                    HStack { Circle().fill(Theme.purple).frame(width: 6, height: 6); Text("Key exposure").font(.caption).foregroundStyle(Theme.secondaryText) }
                }
            }
        } header: { Text("Race Engineer") }
    }

    private var syncSection: some View {
        Section {
            HStack { Text("Auto-sync on launch"); Spacer(); Toggle("Auto-sync", isOn: .constant(true)).tint(Theme.purple).labelsHidden() }.foregroundStyle(Theme.text)
            Button { Task { await viewModel?.manualSync() } } label: { if viewModel?.isSyncing == true { ProgressView() } else { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") } }.foregroundStyle(Theme.text).disabled(viewModel?.isSyncing == true)
        } header: { Text("Sync") } footer: { Text("Sync is best-effort. iOS decides when background work runs; open APEX to refresh.").font(.caption).foregroundStyle(Theme.secondaryText) }
    }

    private var dataSection: some View {
        Section {
            Button(role: .destructive) { viewModel?.showDeleteConfirmation = true } label: { Label("Delete all APEX data", systemImage: "trash") }.foregroundStyle(Theme.text)
        } header: { Text("Data") } footer: { Text("Removes all APEX data. Does not touch Apple Health.").font(.caption).foregroundStyle(Theme.secondaryText) }
    }

    private var aboutSection: some View {
        Section {
            HStack { Text("Version"); Spacer(); Text("1.0").foregroundStyle(Theme.secondaryText) }
            DisclosureGroup { Text("Missing GPS troubleshooting guide content.").font(.caption).foregroundStyle(Theme.secondaryText) } label: { Label("Missing GPS guide", systemImage: "questionmark.circle") }
        } header: { Text("About") }
    }
}

// MARK: - Keychain status

struct KeychainStatus: Sendable {
    let label: String
    let color: Color
}
