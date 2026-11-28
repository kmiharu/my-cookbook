import Foundation
import Observation
import SwiftUI
import UserNotifications

enum LocalFixtureMode {
    static let performance = ProcessInfo.processInfo.arguments.contains("-CatalogLocalStressFixtures")
}

private actor LocalJSON<Value: Codable & Sendable> {
    let fileName: String

    init(fileName: String) {
        self.fileName = fileName
    }

    private var file: URL {
        get throws {
            let directories = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            guard let directory = directories.first else { throw CocoaError(.fileNoSuchFile) }
            return directory
                .appending(path: "CatalogLocalRecords", directoryHint: .isDirectory)
                .appending(path: fileName, directoryHint: .notDirectory)
        }
    }

    func load(defaultValue: Value) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            return defaultValue
        }
    }

    func save(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        let file = try file
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

@MainActor
@Observable
final class LocalRecords<Value: Codable & Sendable> {
    private let disk: LocalJSON<Value>?
    private(set) var value: Value
    private(set) var ready = false
    private(set) var busy = false
    private(set) var failed = false

    init(initial: Value, fileName: String?) {
        value = initial
        disk = fileName.map { LocalJSON(fileName: LocalFixtureMode.performance ? "stress-\($0)" : $0) }
    }

    var canSave: Bool { ready && !busy }

    func load() async {
        guard !ready, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if let disk { value = try await disk.load(defaultValue: value) }
            ready = true
            failed = false
        } catch {
            failed = true
        }
    }

    @discardableResult
    func save(_ next: Value) async -> Bool {
        guard canSave else { return false }
        busy = true
        defer { busy = false }
        do {
            if let disk { try await disk.save(next) }
            value = next
            failed = false
            return true
        } catch {
            failed = true
            return false
        }
    }
}

struct LocalRecordStatus<Value: Codable & Sendable>: View {
    let store: LocalRecords<Value>

    var body: some View {
        if LocalFixtureMode.performance {
            Label("性能測定用の保存先を使用中", systemImage: "gauge.with.dots.needle.67percent")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if store.failed {
            VStack(alignment: .leading, spacing: 8) {
                if store.ready {
                    Label("保存できませんでした。空き容量を確認し、もう一度お試しください。", systemImage: "exclamationmark.circle")
                } else {
                    Label("端末の記録を読み込めませんでした。", systemImage: "exclamationmark.circle")
                    Button("読み込みを再試行") {
                        Task { await store.load() }
                    }
                    .disabled(store.busy)
                }
            }
        } else if !store.ready {
            ProgressView("端末の記録を読み込み中")
        } else if store.busy {
            ProgressView("端末に保存中")
        }
    }
}

@MainActor
enum LocalReminder {
    enum Result: Equatable {
        case scheduled, denied, failed
    }

    static func add(id: String, title: String, components: DateComponents, repeats: Bool = false) async -> Result {
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return .denied }
            let content = UNMutableNotificationContent()
            content.title = title
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
            guard trigger.nextTriggerDate() != nil else { return .failed }
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            return .scheduled
        } catch {
            return .failed
        }
    }

    static func remove(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

extension Duration {
    var localMilliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
