import Foundation

struct HealthKitOnboarding {
    static let shared = HealthKitOnboarding()
    private init() {}

    static func requestAccess() async -> HealthKitAccessResult {
        await HealthKitService.shared.requestAccess()
    }

    static func startImport() -> WorkoutImportStream {
        HealthKitService.shared.importAll()
    }

    static func importSince(startDate: Date?) async -> WorkoutImportResult {
        await HealthKitService.shared.importSince(startDate: startDate)
    }
}
