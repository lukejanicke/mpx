import Foundation
import PlayerLogic

final class HistoryStore {
    static let shared = HistoryStore()
    private var records: [String: ResumeRecord] = [:]
    private let file: URL

    init(file: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.file = file ?? base.appendingPathComponent("mpx/playback-history.json")
        if let data = try? Data(contentsOf: self.file), let saved = try? JSONDecoder().decode([String: ResumeRecord].self, from: data) {
            records = saved
        }
    }

    private func identity(_ url: URL) -> (String, Int64, TimeInterval)? {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let values = try? canonical.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (canonical.path, Int64(size), modified.timeIntervalSince1970)
    }

    func position(for url: URL) -> Double {
        guard let (path, size, modified) = identity(url), let record = records[path] else { return 0 }
        return record.resumePosition(size: size, modified: modified)
    }

    func save(_ url: URL, position: Double, duration: Double, completed: Bool) {
        guard position.isFinite, duration.isFinite, duration > 0, let (path, size, modified) = identity(url) else { return }
        records[path] = ResumeRecord(position: completed ? 0 : max(0, position), duration: duration, size: size,
                                     modified: modified, watched: Date().timeIntervalSince1970)
        if records.count > 1000 {
            let keep = records.sorted { $0.value.watched > $1.value.watched }.prefix(1000)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(records).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            // Playback continues, but leave a diagnostic without logging file names.
            NSLog("mpx could not save playback history: %@", (error as NSError).domain)
        }
    }
}
