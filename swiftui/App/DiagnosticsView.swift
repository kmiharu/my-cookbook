import CatalogCore
import SwiftUI

struct DiagnosticsView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var report: DiagnosticReport?
    @State private var storageAvailable = true
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var exportFailed = false
    @State private var exportFiles = DiagnosticExportFiles()

    var body: some View {
        List {
            Section("記録状況") {
                if let report {
                    LabeledContent("記録する期間", value: "直近 \(report.retentionDays) 日間")
                    LabeledContent("操作・計測の件数", value: report.operationCount.formatted())
                    LabeledContent("アプリ", value: "\(report.app.version) (\(report.app.build))")
                    if report.days.contains(where: \.recordingLimitReached) {
                        Text("1 日の記録上限に達した日があります。").foregroundStyle(.secondary)
                    }
                    if report.operationCount == 0 {
                        Text("サンプルを操作すると記録が表示されます。").foregroundStyle(.secondary)
                    }
                } else if diagnostics == nil {
                    Text("診断の保存先を取得できません。")
                } else {
                    ProgressView("記録を確認中")
                }
                if !storageAvailable {
                    Label("診断を保存できません。空き容量を確認して再試行してください。", systemImage: "exclamationmark.circle")
                    Button("記録を再確認") { Task { await refresh() } }
                }
            }
            if let report, let latest = report.days.last, latest.metrics.contains(where: { $0.measuredCount > 0 }) {
                Section("最新日の計測") {
                    ForEach(Array(latest.metrics.filter { $0.measuredCount > 0 }.prefix(12).enumerated()), id: \.offset) { _, metric in
                        let title = CatalogEntry.all.first(where: { $0.id == metric.sample })?.title ?? "カタログ"
                        let average = metric.totalMilliseconds / Double(metric.measuredCount)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(title) · \(measurementName(metric.action))")
                            Text("平均 \(average, format: .number.precision(.fractionLength(1))) ms · \(metric.measuredCount) 件")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let report {
                let recent = report.days.flatMap(\.recentOperations).suffix(12).reversed()
                if !recent.isEmpty {
                    Section("最近の操作") {
                        ForEach(Array(recent.enumerated()), id: \.offset) { _, event in
                            let title = CatalogEntry.all.first(where: { $0.id == event.sample })?.title ?? "カタログ"
                            LabeledContent {
                                Text(outcomeName(event.outcome)).foregroundStyle(.secondary)
                            } label: {
                                Text("\(title) · \(measurementName(event.action))")
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    guard !isExporting else { return }
                    isExporting = true
                    Task { await prepareExport() }
                } label: {
                    Label("診断を書き出す", systemImage: "doc")
                }
                .disabled(isExporting || diagnostics == nil)
                if isExporting { ProgressView("ファイルを作成中") }
                if exportFailed { Text("ファイルを作成できませんでした。空き容量を確認して再試行してください。") }
                if let exportURL {
                    ShareLink(item: exportURL, preview: SharePreview("SwiftUI サンプルの診断")) {
                        Label("共有する", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("書き出し")
            } footer: {
                Text("画像や入力内容は診断に含まれません。書き出したファイルは共有画面から保存先を選べます。")
            }
        }
        .navigationTitle("診断")
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        guard let diagnostics else { return }
        let snapshot = await diagnostics.snapshot()
        report = snapshot.report
        storageAvailable = snapshot.storageAvailable
    }

    private func prepareExport() async {
        defer { isExporting = false }
        guard let diagnostics else { return }
        exportFailed = false
        do {
            let data = try await diagnostics.exportData()
            exportURL = try await exportFiles.write(data, replacing: exportURL)
        } catch {
            exportFailed = true
        }
        await refresh()
    }

    private func outcomeName(_ outcome: DiagnosticOutcome) -> String {
        switch outcome {
        case .success: "完了"
        case .failure: "失敗"
        case .cancelled: "中断"
        case .limited: "制限あり"
        }
    }

    private func measurementName(_ action: DiagnosticAction) -> String {
        switch action {
        case .open: "起動"
        case .load: "読み込み"
        case .process: "処理"
        case .save: "保存"
        case .play: "再生"
        case .track: "追跡"
        case .ready: "準備完了"
        case .firstFrame: "初回フレーム"
        case .rebuffer: "再バッファ"
        case .seek: "シーク"
        case .frameInterval: "フレーム間隔"
        case .trackingLimited: "追跡制限"
        case .trackingNormal: "通常追跡"
        case .trackingUnavailable: "追跡不可"
        case .thermal: "温度状態"
        case .capture: "撮影"
        }
    }
}

// Write files off the main actor. Reuse the export directory, retaining only recent copies.
private actor DiagnosticExportFiles {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "CatalogDiagnosticExports")

    func write(_ data: Data, replacing oldURL: URL?) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        let newestFirst = files.map { file in
            (file, (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        for (file, _) in newestFirst.dropFirst(3) where file != oldURL {
            try? fm.removeItem(at: file)
        }

        let url = directory.appending(path: "SwiftUI-Diagnostics-\(UUID().uuidString.prefix(8)).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if let oldURL { try? fm.removeItem(at: oldURL) }
        return url
    }
}
