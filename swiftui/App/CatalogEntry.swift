import CatalogCore
import SwiftUI

enum CatalogGroup: String, CaseIterable, Identifiable {
    case discover = "探す・学ぶ"
    case organize = "予定・記録"
    case connect = "連絡・取引"
    case create = "つくる・楽しむ"
    case device = "端末・機器"

    var id: Self { self }
}

enum ConnectionMode: String {
    case local = "端末内"
    case fixture = "再現データ"
    case connected = "実接続"
    case mixed = "実接続・再現データ"

    var icon: String {
        switch self {
        case .local: "iphone"
        case .fixture: "doc.on.doc"
        case .connected: "network"
        case .mixed: "arrow.triangle.branch"
        }
    }
}

struct CatalogEntry: Identifiable {
    let id: SampleID
    let group: CatalogGroup
    let title: String
    let purpose: String
    let icon: String
    let mode: ConnectionMode
    let description: String
    let requirements: String
    let keywords: String

    var searchText: String { [title, purpose, group.rawValue, keywords].joined(separator: " ") }

    static let all: [Self] = [
        .init(id: .catalog, group: .discover, title: "診断を試す", purpose: "サンプル利用を記録する", icon: "waveform.path.ecg",
              mode: .local, description: "テスト操作を記録し、診断タブで件数と共有ファイルを確認します。",
              requirements: "端末内の保存領域を使います。通信や権限は不要です。", keywords: "ログ JSON")
    ]

    @ViewBuilder var screen: some View {
        DiagnosticSampleView()
    }
}

private struct DiagnosticSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @State private var result: String?

    var body: some View {
        List {
            Section {
                Button("テスト操作を記録") {
                    Task {
                        await diagnostics?.record(sample: .catalog, action: .process, outcome: .success)
                        result = await diagnostics?.flush() == true
                            ? "記録しました。診断タブで確認できます。"
                            : "保存できませんでした。空き容量を確認して再試行してください。"
                    }
                }
                if let result { Text(result).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("診断を試す")
    }
}
