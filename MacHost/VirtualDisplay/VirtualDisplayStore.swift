import Foundation

final class VirtualDisplayStore {
    private let key = "MirrorDisplay.VirtualDisplay.records"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRecords() -> [VirtualDisplayRecord] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }

        do {
            return try JSONDecoder().decode([VirtualDisplayRecord].self, from: data)
        } catch {
            return []
        }
    }

    func activeMirrorDisplayRecords() -> [VirtualDisplayRecord] {
        loadRecords().filter { $0.isMirrorDisplayOwned && $0.cleanupStatus != .removed }
    }

    func save(_ record: VirtualDisplayRecord) {
        var records = loadRecords()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        save(records)
    }

    func markRemoved(_ record: VirtualDisplayRecord) {
        var next = record
        next.cleanupStatus = .removed
        save(next)
    }

    func markCleanupFailed(_ record: VirtualDisplayRecord) {
        var next = record
        next.cleanupStatus = .cleanupFailed
        save(next)
    }

    private func save(_ records: [VirtualDisplayRecord]) {
        do {
            let data = try JSONEncoder().encode(records)
            defaults.set(data, forKey: key)
        } catch {
            defaults.removeObject(forKey: key)
        }
    }
}
