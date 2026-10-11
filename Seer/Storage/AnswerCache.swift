import Foundation
import OSLog

/// In-memory answer cache keyed by question fingerprint, optionally persisted as local
/// JSON history in Application Support. Screenshots are never stored.
actor AnswerCache {
    private var records: [AnswerRecord] = []   // newest first
    private let maxRecords: Int
    private var persist: Bool
    private let fileURL: URL?

    init(persist: Bool, maxRecords: Int = 200, directory: URL? = AnswerCache.defaultDirectory) {
        self.persist = persist
        self.maxRecords = maxRecords
        self.fileURL = directory?.appending(path: "history.json")
        if persist, let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([AnswerRecord].self, from: data) {
            records = Array(saved.prefix(maxRecords))
        }
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "Seer")
    }

    func lookup(_ fingerprint: QuestionFingerprint) -> AnswerRecord? {
        records.first { QuestionFingerprintService.isSameQuestion($0.fingerprint, fingerprint) }
    }

    func store(_ record: AnswerRecord) {
        records.removeAll { QuestionFingerprintService.isSameQuestion($0.fingerprint, record.fingerprint) }
        records.insert(record, at: 0)
        if records.count > maxRecords { records.removeLast(records.count - maxRecords) }
        save()
    }

    func all() -> [AnswerRecord] { records }

    func remove(matching fingerprint: QuestionFingerprint) {
        records.removeAll { QuestionFingerprintService.isSameQuestion($0.fingerprint, fingerprint) }
        save()
    }

    func removeAll(kind: QuestionKind) {
        records.removeAll { $0.kind == kind }
        save()
    }

    func clear() {
        records.removeAll()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    func setPersistence(_ enabled: Bool) {
        persist = enabled
        if enabled { save() } else if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func save() {
        guard persist, let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.ui.error("Failed to save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
