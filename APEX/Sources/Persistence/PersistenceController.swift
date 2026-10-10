import SwiftData
import Foundation
import SwiftUI

final class PersistenceController: Sendable, ObservableObject {
    static let shared = PersistenceController()

    let container: ModelContainer
    lazy var fileStore: FileStore = FileStore()

    init() {
        let schema = Schema([Workout.self, Circuit.self, SectorDefinition.self, SectorResult.self, RaceEngineerDebrief.self, AppStateModel.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, allowsSave: true)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer: \(error)")
        }
        let ctx = container.mainContext
        let desc = FetchDescriptor<AppStateModel>()
        if (try? ctx.fetch(desc).first) == nil {
            ctx.insert(AppStateModel())
            try? ctx.save()
        }
    }
}

extension PersistenceController {
    func clearAllData() throws {
        let ctx = container.mainContext
        try? ctx.delete(model: Workout.self)
        try? ctx.delete(model: Circuit.self)
        try? ctx.delete(model: SectorResult.self)
        try? ctx.delete(model: RaceEngineerDebrief.self)
        try? ctx.delete(model: AppStateModel.self)
        try ctx.save()
        try fileStore.deleteAllFiles()
    }
}
