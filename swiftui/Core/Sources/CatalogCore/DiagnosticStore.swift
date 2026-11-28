import Foundation

public enum SampleID: String, CaseIterable, Codable, Sendable {
    case catalog, feed, search, map, learning, chat, social, schedule, ai
    case shopping, booking, expenses, habits, work, journal, studio, playback, spatial, bluetooth
}

public enum DiagnosticAction: String, Codable, Sendable {
    case open, load, process, save, play, track, ready, firstFrame, rebuffer, seek
    case frameInterval, trackingLimited, trackingNormal, trackingUnavailable, thermal, capture
}

public enum DiagnosticOutcome: String, Codable, Sendable {
    case success, failure, cancelled, limited
}

public struct DiagnosticMetadata: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let revision: String
    public let operatingSystem: String
    public let device: String

    public init(version: String, build: String, revision: String, operatingSystem: String, device: String) {
        self.version = version
        self.build = build
        self.revision = revision
        self.operatingSystem = operatingSystem
        self.device = device
    }
}

public struct DiagnosticBuild: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let revision: String
}

public struct DiagnosticMetric: Codable, Sendable {
    public let sample: SampleID
    public let action: DiagnosticAction
    public let outcome: DiagnosticOutcome
    public let recordedBy: DiagnosticBuild?
    public private(set) var count = 0
    public private(set) var measuredCount = 0
    public private(set) var totalMilliseconds = 0.0
    public private(set) var maxMilliseconds = 0.0

    mutating func add(_ milliseconds: Double?) {
        guard count < 1_000_000 else { return }
        count += 1
        guard let milliseconds, milliseconds.isFinite, (0...86_400_000).contains(milliseconds) else { return }
        measuredCount += 1
        totalMilliseconds += milliseconds
        maxMilliseconds = max(maxMilliseconds, milliseconds)
    }
}

public struct DiagnosticOperation: Codable, Sendable {
    public let date: Date
    public let milliseconds: Double?
    public let sample: SampleID
    public let action: DiagnosticAction
    public let outcome: DiagnosticOutcome
    public let recordedBy: DiagnosticBuild?
}

public struct DiagnosticDay: Codable, Sendable {
    public let startUTC: Date
    public let metrics: [DiagnosticMetric]
    public let recentOperations: [DiagnosticOperation]
    public let recordingLimitReached: Bool
}

private struct RecordedOperation: Codable {
    let date: Date
    let sample: SampleID
    let action: DiagnosticAction
    let outcome: DiagnosticOutcome
    let milliseconds: Double?
    let recordedBy: DiagnosticBuild?

    var summary: DiagnosticOperation {
        DiagnosticOperation(date: date, milliseconds: milliseconds, sample: sample, action: action, outcome: outcome,
                            recordedBy: recordedBy)
    }
}

private struct StoredDay: Codable {
    private static let maxOperations = 384
    private static let maxFrameSamples = 640
    var operations: [RecordedOperation] = []
    var frameSamples: [RecordedOperation] = []
    var lastOmission: Date?

    mutating func add(_ record: RecordedOperation) {
        if record.action == .frameInterval, frameSamples.count < Self.maxFrameSamples {
            frameSamples.append(record)
        } else if record.action != .frameInterval, operations.count < Self.maxOperations {
            operations.append(record)
        } else {
            lastOmission = record.date
        }
    }

    mutating func prune(before cutoff: Date) -> Bool {
        let count = operations.count + frameSamples.count
        operations.removeAll { $0.date < cutoff }
        frameSamples.removeAll { $0.date < cutoff }
        let expiredOmission = lastOmission.map { $0 < cutoff } == true
        if expiredOmission { lastOmission = nil }
        return count != operations.count + frameSamples.count || expiredOmission
    }

    func summary(start: Date) -> DiagnosticDay {
        var metrics: [DiagnosticMetric] = []
        for record in operations + frameSamples {
            if let index = metrics.firstIndex(where: {
                $0.sample == record.sample && $0.action == record.action && $0.outcome == record.outcome
                    && $0.recordedBy == record.recordedBy
            }) {
                metrics[index].add(record.milliseconds)
            } else {
                var metric = DiagnosticMetric(sample: record.sample, action: record.action, outcome: record.outcome,
                                              recordedBy: record.recordedBy)
                metric.add(record.milliseconds)
                metrics.append(metric)
            }
        }
        return DiagnosticDay(startUTC: start, metrics: metrics, recentOperations: operations.suffix(40).map(\.summary),
                             recordingLimitReached: lastOmission != nil)
    }
}

public struct DiagnosticReport: Codable, Sendable {
    public let schemaVersion: Int
    public let periodStartUTC: Date
    public let generatedAt: Date
    public let retentionDays: Int
    public let app: DiagnosticMetadata
    public let days: [DiagnosticDay]

    public var operationCount: Int {
        days.reduce(into: 0) { total, day in
            total += day.metrics.reduce(0) { $0 + $1.count }
        }
    }
}

public enum DiagnosticStorageError: Error {
    case recordTooLarge
}

public actor DiagnosticStore {
    public static let retentionDays = 30
    private static let daySeconds: TimeInterval = 86_400
    private static let maxBytesPerDay = 256 * 1024

    private let directory: URL
    private let metadata: DiagnosticMetadata
    private let build: DiagnosticBuild
    private let now: @Sendable () -> Date
    private var days: [Date: StoredDay] = [:]
    private var dirty: Set<Date> = []
    private var loaded = false
    private var storageFailed = false
    private var pendingFlush: Task<Void, Never>?

    public init(directory: URL, metadata: DiagnosticMetadata, now: @escaping @Sendable () -> Date = { .now }) {
        self.directory = directory
        self.metadata = metadata
        self.build = DiagnosticBuild(version: metadata.version, build: metadata.build, revision: metadata.revision)
        self.now = now
    }

    public func record(
        sample: SampleID, action: DiagnosticAction, outcome: DiagnosticOutcome, milliseconds: Double? = nil
    ) {
        let date = now()
        prepare(at: date)
        let start = Self.dayStart(date)
        var day = days[start] ?? StoredDay()
        let duration = milliseconds.flatMap { $0.isFinite && (0...86_400_000).contains($0) ? $0 : nil }
        day.add(RecordedOperation(
            date: date, sample: sample, action: action, outcome: outcome, milliseconds: duration, recordedBy: build
        ))
        days[start] = day
        dirty.insert(start)
        scheduleFlush()
    }

    public func flush() -> Bool {
        flush(at: now())
    }

    private func flush(at date: Date) -> Bool {
        pendingFlush?.cancel()
        pendingFlush = nil
        prepare(at: date)
        guard loaded else { return false }
        let cutoff = Self.cutoff(date)
        let oldestDay = Self.dayStart(cutoff)
        if days[oldestDay]?.prune(before: cutoff) == true { dirty.insert(oldestDay) }
        do {
            try purgeDisk(before: oldestDay)
            for date in dirty.sorted() {
                guard let day = days[date] else { continue }
                let data = try encoder().encode(day)
                guard data.count <= Self.maxBytesPerDay else { throw DiagnosticStorageError.recordTooLarge }
                #if os(iOS)
                try data.write(to: file(for: date), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: file(for: date), options: .atomic)
                #endif
                dirty.remove(date)
            }
            storageFailed = false
        } catch {
            storageFailed = true
        }
        return !storageFailed
    }

    public func snapshot() -> (report: DiagnosticReport, storageAvailable: Bool) {
        let date = now()
        let available = flush(at: date)
        return (DiagnosticReport(
            schemaVersion: 1, periodStartUTC: Self.cutoff(date), generatedAt: date,
            retentionDays: Self.retentionDays, app: metadata,
            days: days.keys.sorted().compactMap { start in days[start]?.summary(start: start) }
        ), available)
    }

    public func exportData() throws -> Data {
        let result = snapshot()
        return try encoder(pretty: true).encode(result.report)
    }

    private func scheduleFlush() {
        guard pendingFlush == nil else { return }
        pendingFlush = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            _ = await self?.flush()
        }
    }

    private func prepare(at date: Date) {
        guard !loaded else {
            let oldestDay = Self.dayStart(Self.cutoff(date))
            days = days.filter { $0.key >= oldestDay && $0.key <= Self.dayStart(date) }
            dirty = dirty.filter { days[$0] != nil }
            return
        }
        let cutoff = Self.dayStart(Self.cutoff(date))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            var privateDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try privateDirectory.setResourceValues(values)
            #endif
            try purgeDisk(before: cutoff)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            for file in try dayFiles() {
                guard let start = fileDate(file), start >= cutoff, start <= Self.dayStart(date) else { continue }
                let contents = try file.resourceValues(forKeys: [.fileSizeKey])
                guard let fileSize = contents.fileSize, fileSize <= Self.maxBytesPerDay else { continue }
                // Skip records whose write was interrupted or whose schema is unreadable.
                if let data = try? Data(contentsOf: file), var day = try? decoder.decode(StoredDay.self, from: data) {
                    if let pending = days[start] {
                        for record in pending.operations + pending.frameSamples { day.add(record) }
                        if let omission = pending.lastOmission { day.lastOmission = omission }
                    }
                    days[start] = day
                }
            }
            loaded = true
        } catch {
            storageFailed = true
        }
    }

    private func purgeDisk(before cutoff: Date) throws {
        for file in try dayFiles() {
            guard let date = fileDate(file), date < cutoff else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    private func dayFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }
    }

    private func file(for start: Date) -> URL {
        directory.appendingPathComponent("\(Int(start.timeIntervalSince1970)).json")
    }

    private func fileDate(_ url: URL) -> Date? {
        Int(url.deletingPathExtension().lastPathComponent).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private static func cutoff(_ date: Date) -> Date {
        date.addingTimeInterval(-Double(retentionDays) * daySeconds)
    }

    private static func dayStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / daySeconds) * daySeconds)
    }

    private func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = pretty ? .iso8601 : .secondsSince1970
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }
}
