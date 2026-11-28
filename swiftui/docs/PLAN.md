# SwiftUI サンプルを作り、iPhone で確かめる計画

対象は `kmiharu/my-cookbook` の `swiftui/`。調査時のベースは `e5e2429`。ルートの AGENTS.md に従い、既存サンプルと独立した題材フォルダに置く。参照した既存の iOS カメラアプリには署名なし Simulator ビルドの Codemagic 実績がある。そこで使うアプリやテスターは変更しない。配信権限と設定の詳細は [配信手順](RELEASE.md) に記録する。

調査基準日は 2026-11-28。正式版 iOS 27.2.1 を検証基準、Deployment Target を iOS 27.2、Xcode 27.2 (27B52) と iOS 27.2 SDK、同梱 Swift 6.4 の Swift 6 言語モードを CI 基準とする。Codemagic の公開イメージで確認した。Linux は Foundation コアのテストとソースの構文確認を担う。

[Apple セキュリティリリース](https://support.apple.com/ja-jp/100100) · [Xcode 27.2](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes) · [Codemagic Xcode 27.2](https://docs.codemagic.io/specs-macos/xcode-27-2/)

## 段階と判定

1. 共通カタログ、案内、検索、端末内診断、書き出しを実装する。Swift Package で保持・上限・容量不足時の再試行をテストする。初回の Codemagic ビルド、署名、TestFlight インストールを追跡する。
2. カメラ・写真編集・HLS・AR を統合する。権限拒否、中断・復帰、熱状態と連続操作を実機検証する。実機が得られない間は計測点と再現手順を整える。
3. 残りの用途を下表の単位で統合する。各 README に状態、依存、制約、測定条件と判定を記載する。再現データやテスト取引は入口と操作画面で識別する。
4. カタログと実装・設計の照合、シミュレータ・実機・負荷結果の更新、TestFlight 更新を行う。コミット、バージョン、CI、App Store Connect を紐付ける。

## 用途別の実装・検証一覧

負荷条件は測定計画。共通の初回候補は iPhone 16、iOS 27.2.1。各 README の数値は測定結果と区別する。Simulator と実機の結果は [検証記録](VERIFICATION.md) に記載する。

| 用途 | 試せる操作とコード入口 | 依存・設定 | 検証条件 |
| --- | --- | --- | --- |
| 情報を得る | フィード、追加読み込み、詳細、ブックマーク · `FeedSampleView` | HTTPS および再現データ | キャッシュ上限、オフライン再試行、連続ページ読み込み |
| 調べる・比較する | 絞り込み、並べ替え、比較、条件保存 · `SearchSampleView` | ローカル生成データ | 1 万件、連続入力、古い結果の棄却 |
| 移動する | 地図、現在地、周辺、経路 · `MapSampleView` | MapKit、位置の許可、通信 | 位置取得をタップ時に限定、拒否と通信断、退出時に停止 |
| 学ぶ | 学習、クイズ、読み上げ、履歴 · `LearningSampleView` | 端末内の音声と教材 | 連続回答、進捗の復元、退出時の音声停止 |
| 連絡・相談する | 会話、写真添付、失敗と再送 · `ChatSampleView` | 写真選択、再現用の送信先 | 再送と連続入力、添付の縮小、二重送信の防止 |
| 発信・交流する | 下書き、写真、投稿、反応 · `SocialSampleView` | 写真選択、ローカルフィード | ページ境界と画像付き投稿の再読み込み |
| 予定を決める・共同で進める | 日付、タスク、通知、共有リストの再現 · `ScheduleSampleView` | 通知は任意許可、競合は再現 | 日付境界、通知拒否、更新競合 |
| AI に相談する | 会話、逐次表示、中断、履歴 · `AISampleView` | ローカル再現応答 | 中断後の追記が無いこと、長文、履歴上限 |
| 買う | 商品、詳細、保存、カート、テスト購入 · `ShoppingSampleView` | 再現データと模擬決済 | 連続タップ、再起動、注文状態の復元 |
| 予約する | 空き枠、予約、変更、取消 · `BookingSampleView` | 再現データと模擬予約 | 日付、重複、失敗後の再試行 |
| お金を記録する | 支出、分類、予算と集計 · `ExpenseSampleView` | 端末内、整数の円 | 境界金額と月またぎ、集計の整合 |
| 健康・習慣を記録する | 日ごとの記録、目標、継続 · `HabitSampleView` | 端末内、通知は任意許可 | 日付境界、再起動、記録件数 |
| 仕事・手続きをする | フォーム、画像 OCR、コード読取、書類出力 · `WorkSampleView` | Vision、写真選択または再現画像 | 大画像、連続入力、キャンセル |
| 思い出を残す | 写真、録音、日記保存 · `DiarySampleView` | カメラ・マイク許可、実機 | セッション離脱、拒否、録音中断、保存失敗 |
| 作る・編集する | 写真、切り抜き、フィルタ、描画、取り消し、出力 · `ImageEditingSampleView` | 写真選択または再現画像 | 大画像、切り替え連打、処理待ち上限 |
| 見る・聴く | HLS、シーク、再試行、中断 · `PlaybackSampleView` | Apple 公開テスト配信、HTTPS | Wi-Fi と帯域制限、開始時間、停止時間、メモリ、10 分利用 |
| 遊ぶ・空間を使う | 小さなゲーム、AR 配置、移動とリセット · `SpatialSampleView` | 対応 iPhone、カメラ許可 | 追跡制限、復帰と連続利用時の熱・描画負荷 |
| 機器とつなぐ | BLE 探索、接続、情報と RSSI の読取、切断・再接続 · `BluetoothSampleView` | Bluetooth 許可、BLE 周辺機器 | 走査期限、接続失敗、圏外と再接続 |
