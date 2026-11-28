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
    case mixed = "実接続・再現データ"

    var icon: String {
        switch self {
        case .local: "iphone"
        case .fixture, .localAndFixture: "doc.on.doc"
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
        .init(id: .feed, group: .discover, title: "記事を読む", purpose: "ニュースの一覧とブックマーク", icon: "newspaper",
              mode: .mixed, description: "フィードを読み込み、一覧から記事を選んでブックマークに残します。再現データに切り替えて通信なしで動作を試せます。",
              requirements: "実接続にはインターネットが必要です。フィードは Hacker News の英語記事を表示します。", keywords: "情報 ニュース 記事 API ページ分割 キャッシュ URLSession"),
        .init(id: .search, group: .discover, title: "調べる・比較する", purpose: "条件を組み合わせて候補を絞る", icon: "magnifyingglass",
              mode: .fixture, description: "条件で絞り込み、並べ替え、候補を比較します。使った条件を保存して呼び出せます。",
              requirements: "1 万件の再現データを端末内で検索します。", keywords: "検索 大量データ キャンセル"),
        .init(id: .map, group: .discover, title: "近くを探して移動する", purpose: "地図・現在地・周辺・経路", icon: "map",
              mode: .mixed, description: "東京駅や現在地の周辺を検索し、施設への徒歩経路を表示します。場所と直線経路の見本もあります。",
              requirements: "周辺検索と経路には通信が必要です。現在地を使う場合は、使用中の位置情報を許可します。", keywords: "移動 位置情報 経路 MapKit"),
        .init(id: .learning, group: .discover, title: "教材で学ぶ", purpose: "読み上げ・クイズ・学習の進み具合", icon: "book",
              mode: .local, description: "教材を読み、読み上げを聞き、クイズに答えて学習履歴を残します。",
              requirements: "教材と履歴は端末内にあります。読み上げはシステムの音声を使います。", keywords: "勉強 学習 音声 アクセシビリティ"),
        .init(id: .schedule, group: .organize, title: "予定とタスクを決める", purpose: "日付・通知・共同編集の再現", icon: "calendar",
              mode: .localAndFixture, description: "日付を選んでタスクを追加し、完了やリマインダーを設定します。共同編集の競合を再現して解決できます。",
              requirements: "通知は任意です。共有リストの競合は端末内の再現データで試します。", keywords: "カレンダー リマインダー 共同 共有"),
        .init(id: .expenses, group: .organize, title: "支出を記録する", purpose: "分類・予算・月ごとの集計", icon: "yensign.circle",
              mode: .local, description: "円単位の支出を登録して分類別のグラフや予算との比較を確認します。",
              requirements: "端末内に保存します。銀行口座や決済サービスの設定は不要です。", keywords: "家計 お金 費用 金額 Charts"),
        .init(id: .habits, group: .organize, title: "習慣を記録する", purpose: "毎日の達成・目標・継続日数", icon: "checkmark.circle",
              mode: .local, description: "目標を設定して日ごとの実績を記録し、継続日数やグラフを確認します。",
              requirements: "習慣の記録は端末内に保存します。リマインダーを使う場合は通知を許可します。", keywords: "健康 記録 目標 通知 グラフ"),
        .init(id: .chat, group: .connect, title: "メッセージを送る", purpose: "会話・写真添付・再送", icon: "bubble.left.and.bubble.right",
              mode: .fixture, description: "再現用の会話で添付と送信状態を確認します。失敗を再現して同じメッセージを再送できます。",
              requirements: "送信は端末内のシミュレーションです。写真選択は任意です。", keywords: "連絡 チャット 相談 添付"),
        .init(id: .social, group: .connect, title: "投稿して反応を付ける", purpose: "下書き・投稿・写真・リアクション", icon: "rectangle.stack",
              mode: .fixture, description: "写真付きの下書きから投稿し、フィードで読み返して反応を付けられます。",
              requirements: "フィードと下書きは端末内に保存します。写真選択は任意です。", keywords: "発信 SNS タイムライン"),
        .init(id: .ai, group: .connect, title: "AI に相談する流れを試す", purpose: "応答の逐次表示・中断・履歴", icon: "text.bubble",
              mode: .fixture, description: "質問を送り、再現応答が少しずつ表示される様子や、途中で停止したときの履歴を確認します。",
              requirements: "応答は端末内の再現データです。推論や API 接続は未設定です。", keywords: "AI LLM ストリーミング 会話 キャンセル"),
        .init(id: .shopping, group: .connect, title: "買い物を試す", purpose: "商品・お気に入り・カート・テスト購入", icon: "cart",
              mode: .fixture, description: "商品を探し、カートに入れて模擬購入の手順を進めます。注文の状態を読み返せます。",
              requirements: "再現データと模擬決済を使います。料金は発生しません。", keywords: "買う 買い物 商品 注文 購入"),
        .init(id: .booking, group: .connect, title: "予約を試す", purpose: "空き枠・申し込み・変更・取消", icon: "calendar.badge.clock",
              mode: .fixture, description: "空き枠を選び、模擬予約を作成、変更、取消します。再試行時の重複防止を試せます。",
              requirements: "予約先と空き枠は端末内の再現データです。", keywords: "予約 日付 再試行 重複"),
        .init(id: .work, group: .organize, title: "書類を作って出力する", purpose: "フォーム・文字認識・コード読み取り", icon: "doc.text.viewfinder",
              mode: .local, description: "画像内の文字とコードを読み取り、フォームを確認してファイルを書き出します。",
              requirements: "再現画像またはシステムの写真選択を使います。認識処理は端末内で行います。", keywords: "仕事 手続き OCR Vision ファイル"),
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
              mode: .local, description: "ミニゲームで操作を試し、対応端末では AR でブロックを置き、追跡と配置をリセットできます。",
              requirements: "AR は対応する iPhone とカメラ許可が必要です。ゲームはカメラなしで遊べます。", keywords: "ゲーム AR ARKit RealityKit 追跡"),
        .init(id: .bluetooth, group: .device, title: "Bluetooth 機器とつなぐ", purpose: "探索・接続・機器情報の読み取り", icon: "antenna.radiowaves.left.and.right",
              mode: .mixed, description: "機器を探し、接続して情報と電波の強さを読み取ります。再現モードでも接続や切断を試せます。",
              requirements: "実接続は Bluetooth の許可と BLE 周辺機器が必要です。読み取れる情報は機器の仕様で異なります。", keywords: "機器 BLE CoreBluetooth 接続 RSSI")
    ]

    @ViewBuilder var screen: some View {
        switch id {
        case .catalog: DiagnosticsView()
        case .feed: FeedSampleView()
        case .search: SearchSampleView()
        case .map: MapSampleView()
        case .learning: LearningSampleView()
        case .chat: ChatSampleView()
        case .social: SocialSampleView()
        case .schedule: ScheduleSampleView()
        case .ai: AISampleView()
        case .shopping: ShoppingSampleView()
        case .booking: BookingSampleView()
        case .expenses: ExpenseSampleView()
        case .habits: HabitSampleView()
        case .work: WorkSampleView()
        case .journal: DiarySampleView()
        case .studio: ImageEditingSampleView()
        case .playback: PlaybackSampleView()
        case .spatial: SpatialSampleView()
        case .bluetooth: BluetoothSampleView()
        }
    }
}
