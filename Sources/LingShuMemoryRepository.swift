import Foundation

final class LingShuMemoryRepository {
    private let defaults: UserDefaults
    private let mainThreadMemoryKey = "lingshu.main-thread.memory.records"
    private let taskMemoryKey = "lingshu.task.memory.records"
    private let coldMemoryKey = "lingshu.cold.memory.records"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadMainThreadRecords() -> [MainThreadMemoryRecord] {
        loadArray(MainThreadMemoryRecord.self, forKey: mainThreadMemoryKey)
    }

    func saveMainThreadRecords(_ records: [MainThreadMemoryRecord]) {
        save(records, forKey: mainThreadMemoryKey)
    }

    func loadTaskRecords() -> [TaskMemoryRecord] {
        loadArray(TaskMemoryRecord.self, forKey: taskMemoryKey)
    }

    func saveTaskRecords(_ records: [TaskMemoryRecord]) {
        save(records, forKey: taskMemoryKey)
    }

    func loadColdRecords() -> [ColdMemoryRecord] {
        loadArray(ColdMemoryRecord.self, forKey: coldMemoryKey)
    }

    func saveColdRecords(_ records: [ColdMemoryRecord]) {
        save(records, forKey: coldMemoryKey)
    }

    private func loadArray<T: Decodable>(_ type: T.Type, forKey key: String) -> [T] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([T].self, from: data) else {
            return []
        }
        return decoded
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
