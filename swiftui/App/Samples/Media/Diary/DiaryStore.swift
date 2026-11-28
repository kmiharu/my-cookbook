import Foundation

struct DiaryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let note: String
    let place: String
    let hasPhoto: Bool
    let hasAudio: Bool
}

enum DiaryStoreError: LocalizedError {
    case invalidInput, limitReached, audioTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidInput: "日記は 1〜400 文字、場所は 80 文字以内で入力してください。"
        case .limitReached: "日記は 50 件まで保管できます。不要な日記を削除すると追加できます。"
        case .audioTooLarge: "音声ファイルが大きすぎます。短く録り直してください。"
        }
    }
}

actor DiaryStore {
    private let folderName = "SampleDiary"

    func entries() throws -> [DiaryEntry] {
        let folder = try root()
        let entries = try readIndex(at: folder)
        let known = Set(entries.map { $0.id.uuidString })
        // Directory names are generated UUIDs. Preserve unknown files even if metadata is missing.
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for file in files where UUID(uuidString: file.lastPathComponent) != nil && !known.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        return entries
    }

    func save(note: String, place: String, photo: MediaImageAsset?, audio: URL?) throws -> [DiaryEntry] {
        try Task.checkCancellation()
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...400).contains(note.count), place.count <= 80 else { throw DiaryStoreError.invalidInput }

        let folder = try root()
        var entries = try readIndex(at: folder)
        guard entries.count < 50 else { throw DiaryStoreError.limitReached }
        let entry = DiaryEntry(id: UUID(), date: .now, note: note, place: place,
                               hasPhoto: photo != nil, hasAudio: audio != nil)
        let item = itemURL(entry, in: folder)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        do {
            if let photo {
                try photo.full.write(to: item.appendingPathComponent("photo.jpg"), options: .atomic)
                try photo.preview.write(to: item.appendingPathComponent("thumbnail.jpg"), options: .atomic)
            }
            if let audio {
                let metadata = try audio.resourceValues(forKeys: [.fileSizeKey])
                guard let bytes = metadata.fileSize, bytes <= 512 * 1_024 else { throw DiaryStoreError.audioTooLarge }
                try FileManager.default.copyItem(at: audio, to: item.appendingPathComponent("audio.m4a"))
            }
            try Task.checkCancellation()
            entries.insert(entry, at: 0)
            try writeIndex(entries, at: folder)
            return entries
        } catch {
            try? FileManager.default.removeItem(at: item)
            throw error
        }
    }

    func delete(_ entry: DiaryEntry) throws -> [DiaryEntry] {
        let folder = try root()
        var entries = try readIndex(at: folder)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return entries }
        entries.remove(at: index)
        try writeIndex(entries, at: folder)
        try? FileManager.default.removeItem(at: itemURL(entry, in: folder))
        return entries
    }

    func detail(for entry: DiaryEntry) throws -> (photo: Data?, audio: URL?) {
        try Task.checkCancellation()
        let folder = try itemURL(entry, in: root())
        let photo = entry.hasPhoto ? try Data(contentsOf: folder.appendingPathComponent("thumbnail.jpg")) : nil
        let audio = entry.hasAudio ? folder.appendingPathComponent("audio.m4a") : nil
        return (photo, audio)
    }

    func photo(for entry: DiaryEntry) throws -> Data {
        try Task.checkCancellation()
        return try Data(contentsOf: itemURL(entry, in: root()).appendingPathComponent("photo.jpg"))
    }

    private func root() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func readIndex(at root: URL) throws -> [DiaryEntry] {
        let index = root.appendingPathComponent("diary.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        return try JSONDecoder().decode([DiaryEntry].self, from: Data(contentsOf: index))
    }

    private func writeIndex(_ entries: [DiaryEntry], at root: URL) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: root.appendingPathComponent("diary.json"), options: .atomic)
    }

    private func itemURL(_ entry: DiaryEntry, in root: URL) -> URL {
        root.appendingPathComponent(entry.id.uuidString, isDirectory: true)
    }
}
