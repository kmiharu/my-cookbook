# SwiftUI のサンプルを選んで iPhone で試す

18 の用途を一つの iPhone アプリにまとめたサンプル集です。アプリでは「写真を加工する」「予定とタスクを決める」など、目的でサンプルを探せます。案内で利用条件を確認して開き、「診断」から操作結果や計測情報を書き出せます。

## 起動して試す

正式版 iOS 27.2.1 を実機検証の基準とします。Deployment Target は 27.2。macOS では Xcode 27.2（27B52）、iOS SDK 27.2、同梱 Swift 6.4 系の Swift 6 言語モードを使用します。

```sh
# リポジトリのルートで
bash swiftui/ci/ios.sh verify

# 生成後に Xcode で開き、SwiftUICatalog スキームを実行
open swiftui/SwiftUICatalog.xcodeproj
```

Linux では `swift test --package-path swiftui/Core` で Foundation の自動テストを実行できます。`bash swiftui/checks/booking/verify.sh` は予約モデルの再試行と入力検証を実行します。TestFlight は GitHub Actions またはローカルコマンドから、署名・アップロード、処理確認、内部テスターへの配布を順に進められます。設定とコマンドは [配信手順](docs/RELEASE.md)、実行済みの結果と端末の操作手順は [検証記録](docs/VERIFICATION.md) にあります。

## 用途からコードを読む

| できること | 接続と再現条件 | コードと試し方 |
| --- | --- | --- |
| 記事を読み、あとで読む一覧に残す | Hacker News または再現データ | [記事とブックマーク](App/Samples/Connected/Feed/) |
| 条件で探し、候補を見比べる | 1 万件の生成データ | [検索と比較](App/Samples/Local/Search/) |
| 地図で周辺を探し、徒歩経路を見る | MapKit と通信。現在地の許可は任意 | [地図と経路](App/Samples/Connected/Map/) |
| 教材を聞き、クイズと履歴を試す | 端末内 | [学習](App/Samples/Local/Learning/) |
| 会話で写真を添付し、送信失敗後に再送する | 模擬送信 | [メッセージ](App/Samples/Fixtures/Chat/) |
| 写真付きの下書きから投稿し、反応を付ける | 端末内のフィード | [投稿](App/Samples/Fixtures/Social/) |
| タスクと通知を設定し、共同編集の競合を試す | 端末内と再現用の共有リスト | [予定とタスク](App/Samples/Local/Schedule/) |
| 応答の逐次表示を止め、会話履歴に戻る | 再現応答。推論・AI API 未設定 | [AI 会話](App/Samples/Fixtures/AI/) |
| 商品をカートに入れ、注文状態を確かめる | 模擬決済 | [買い物](App/Samples/Fixtures/Shopping/) |
| 空き枠を選び、予約を変更・取消する | 模擬予約 | [予約](App/Samples/Fixtures/Booking/) |
| 円単位で支出を記録し、予算と比較する | 端末内 | [支出](App/Samples/Local/Expenses/) |
| 毎日の習慣を記録し、継続を確認する | 端末内。通知は任意 | [習慣](App/Samples/Local/Habits/) |
| 文字とコードを読み取り、書類を出力する | Vision と再現画像または写真選択 | [フォームと OCR](App/Samples/Connected/Work/) |
| 写真や音声を添えて日記を書く | 撮影・録音には実機と許可 | [写真と音声の日記](App/Samples/Media/Diary/) |
| 写真を切り抜き、加工して書き出す | 端末内と再現画像 | [画像編集](App/Samples/Media/Studio/) |
| 動画を再生し、シークや通信復帰を試す | Apple HLS テスト配信とローカル音声 | [動画と音声](App/Samples/Media/Playback/) |
| ゲームで遊び、AR で物を置く | AR は対応実機とカメラ許可 | [ゲームと AR](App/Samples/Media/Spatial/) |
| BLE 機器から情報を読み取る | 対応機器・許可、または再現モード | [Bluetooth](App/Samples/Connected/Bluetooth/) |

## アプリの構成

- [CatalogApp.swift](App/CatalogApp.swift) がアプリの入口です。シーンの復帰とバックグラウンド遷移で診断を保存します。
- [CatalogEntry.swift](App/CatalogEntry.swift) に目的、検索語、利用条件、接続種別、起動先を定義します。[CatalogView.swift](App/CatalogView.swift) が一覧と案内を表示します。
- [App/Samples](App/Samples/) の各サンプルは画面と処理の近くに README を置きます。データアクセスを共有している箇所と、他のアプリへ移す際の変更箇所は各 README にあります。
- [Core](Core/) には iOS SDK なしで検証できる診断保存と入力検証を置きます。書き出す内容と保持・共有の詳細は [診断](docs/DIAGNOSTICS.md) にあります。
- [OpenPencil のデザインと SwiftUI の対応](design/README.md) に編集可能な成果物、配色、文字、状態、操作の仕様があります。
- [計画](docs/PLAN.md) に段階別の完了条件、[公式資料](docs/REFERENCES.md) に Apple、GitHub、Codemagic、OpenPencil の参照先があります。

チャット、投稿、共同編集、購入、予約、AI は端末内の再現を用意しています。外部サービス上の送信・取引・推論を行うためのアカウントや接続設定は含みません。
