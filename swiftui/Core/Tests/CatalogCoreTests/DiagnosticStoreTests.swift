import Foundation
import Testing
@testable import CatalogCore

private let metadata = DiagnosticMetadata(version: "1.0", build: "42", revision: "abcdef", operatingSystem: "test", device: "fixture")
private let day: TimeInterval = 86_400
private let today = Date(timeIntervalSince1970: 20_000 * day + 3_600)

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

@Test func retainsThirtyFullDaysAndPrunesTheBoundaryFile() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    for age in [28 * day, 30 * day - 60, 30 * day + 60, 31 * day] {
        let store = DiagnosticStore(directory: directory, metadata: metadata, now: { today - age })
        await store.record(sample: .catalog, action: .open, outcome: .success)
        #expect(await store.flush())
    }

    let store = DiagnosticStore(directory: directory, metadata: metadata, now: { today })
    let snapshot = await store.snapshot()
    #expect(snapshot.storageAvailable)
    #expect(snapshot.report.operationCount == 2)
    #expect(snapshot.report.days.first?.recentOperations.first?.date == today - 30 * day + 60)
    #expect(snapshot.report.periodStartUTC == today - 30 * day)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(files.count == 2)
}

@Test func aggregatesWithinADayAndBoundsRecentOperations() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiagnosticStore(directory: directory, metadata: metadata, now: { today })
    for value in 1...60 {
        await store.record(sample: .playback, action: .firstFrame, outcome: .success, milliseconds: Double(value))
    }
    await store.record(sample: .playback, action: .firstFrame, outcome: .success, milliseconds: .infinity)
    await store.record(sample: .spatial, action: .frameInterval, outcome: .success, milliseconds: 20)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let exported = try await store.exportData()
    let report = try decoder.decode(DiagnosticReport.self, from: exported)
    #expect(report.schemaVersion == 1)
    #expect(report.app == metadata)
    let summary = try #require(report.days.first)
    #expect(summary.recentOperations.count == 40)
    #expect(summary.recentOperations.last?.action == .firstFrame)
    let metric = try #require(summary.metrics.first)
    #expect(metric.count == 61)
    #expect(metric.measuredCount == 60)
    #expect(metric.maxMilliseconds == 60)
    #expect(metric.totalMilliseconds == 1_830)
}

@Test func storageFailureKeepsPendingRecordsForRetry() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("file blocks directory".utf8).write(to: directory)
    let store = DiagnosticStore(directory: directory, metadata: metadata, now: { today })
    await store.record(sample: .search, action: .process, outcome: .success)
    let unavailable = await store.snapshot()
    #expect(!unavailable.storageAvailable)
    #expect(unavailable.report.operationCount == 1)

    try FileManager.default.removeItem(at: directory)
    #expect(await store.flush())
    let reopened = DiagnosticStore(directory: directory, metadata: metadata, now: { today })
    #expect(await reopened.snapshot().report.operationCount == 1)
}

@Test func boundsDiskUsageWithoutDiscardingOlderDays() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let previous = DiagnosticStore(directory: directory, metadata: metadata, now: { today - day })
    await previous.record(sample: .catalog, action: .open, outcome: .success)
    #expect(await previous.flush())

    let store = DiagnosticStore(directory: directory, metadata: metadata, now: { today })
    for _ in 0..<1_100 {
        await store.record(sample: .spatial, action: .frameInterval, outcome: .success, milliseconds: 20)
        await store.record(sample: .chat, action: .save, outcome: .failure)
    }
    let snapshot = await store.snapshot()
    #expect(snapshot.storageAvailable)
    #expect(snapshot.report.days.last?.recordingLimitReached == true)
    #expect(snapshot.report.days.last?.metrics.reduce(0) { $0 + $1.count } == 1_024)
    #expect(snapshot.report.days.first?.recentOperations.count == 1)
}
