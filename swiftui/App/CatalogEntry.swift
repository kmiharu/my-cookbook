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
    case localAndFixture = "端末内・再現データ"
    case connected = "実接続"
    case mixed = "実接続・再現データ"

    var icon: String {
        switch self {
        case .local: "iphone"
        case .fixture, .localAndFixture: "doc.on.doc"
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
        .init(id: .journal, group: .create, title: "思い出を残す", purpose: "日記・写真・音声メモ", icon: "camera",
              mode: .local, description: "日記に写真や音声を添えて保存し、記録一覧から開き直します。",
              requirements: "撮影はカメラ、録音はマイクを許可します。写真はシステムの選択画面から追加できます。", keywords: "日記 写真 カメラ 録音 AVFoundation"),
        .init(id: .studio, group: .create, title: "写真を加工する", purpose: "切り抜き・フィルタ・描画・書き出し", icon: "slider.horizontal.3",
              mode: .local, description: "写真を編集し、プレビューで結果を確認します。編集を取り消し、完成した画像を共有できます。",
              requirements: "再現画像か写真選択を使います。処理と書き出しは端末内で行います。", keywords: "創作 写真 画像 加工 編集 Core Image"),
        .init(id: .playback, group: .create, title: "動画を見る・音を聞く", purpose: "HLS の再生・シーク・再試行", icon: "play.rectangle",
              mode: .mixed, description: "HLS 動画と端末内の短いテスト音声を再生します。準備完了、最初のフレーム、再バッファを診断で確認できます。",
              requirements: "HLS には Apple の公開テスト配信と通信が必要です。端末内の音声は通信なしで試せます。", keywords: "動画 音声 HLS AVPlayer AVKit"),
        .init(id: .spatial, group: .device, title: "遊ぶ・空間に置く", purpose: "ミニゲーム・AR の配置と操作", icon: "arkit",
              mode: .local, description: "ミニゲームで操作を試し、対応端末では AR で物体を配置して動かします。",
              requirements: "AR は対応する iPhone とカメラ許可が必要です。ゲームはカメラなしで遊べます。", keywords: "ゲーム AR ARKit RealityKit 追跡"),
    ]

    @ViewBuilder var screen: some View {
        switch id {
        case .journal: DiarySampleView()
        case .studio: ImageEditingSampleView()
        case .playback: PlaybackSampleView()
        case .spatial: SpatialSampleView()
        default: DiagnosticsView()
        }
    }
}
