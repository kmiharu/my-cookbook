# メッセージを書いて添付し、送信エラーから再送する

## コードの入口

[ChatSampleView.swift](ChatSampleView.swift) の `ChatSampleView` → `submitDraft` → `send` → `save` の順に読みます。

## 状態とデータの流れ

入力と選択画像は画面状態です。送信開始時に UUID と時刻を付けて `.queued` を保存します。約650 ms後、再現用の成功または失敗を同じ UUID に上書きします。中断中のメッセージは再送できる状態になります。起動時に以前の `.queued` を読み込んだ場合も再送を案内します。

## 実装を選んだ理由

滞留中の行を一度保存してから処理するため、画面が閉じられても入力を戻せます。PhotosPicker から受け取ったファイルを ImageIO で320 pxのJPEGに縮小します。[FixtureDisk](../Support/FixtureDisk.swift) はアクターでファイル更新を直列化し、アトミックに置き換えます。

## 他のアプリで置き換える箇所

`send` の待機と判定を transport に置き換えます。サーバーには UUID を再送キーとして渡し、応答が途切れた場合は送達を照会します。保存件数、認証、添付のアップロード、会話の識別子は対象サービスに合わせます。

## 依存と制約

入力写真は32 MiB・1億画素以下です。写真を添付する場合はシステムの写真選択画面を使います。会話相手、アカウント、サーバー接続はありません。保存上限は直近20件、1件500文字、JPEG 128 KBです。端末内の会話ファイルに本文とサムネイルを保存し、診断には結果と経過時間を記録します。

## 性能目標と測定方法

iPhone 17、iOS 27.2.1、機内モード、12 MPの端末内写真で添付し、履歴20件の状態で送信・再送を30回行います。送信開始から再現結果までの目標はP95で1秒以下（650 msの再現待ち込み）。診断の最大値と平均に加え、Instruments の Time Profiler で送信クリックから結果表示までを計測します。Allocationsで、キャンセル後にオリジナル画像と実行タスクが残っていないことを確認します。目標値です。

## 公式資料と出典

Appleの PhotosPicker、Swift Concurrency と ImageIO（確認日 2026-11-28、iOS SDK 27.2）。選択式の写真アクセス、タスク中断、縮小デコードに採用しました。外部コードの取り込みはありません。 [PhotosPicker](https://developer.apple.com/documentation/photosui/photospicker) · [Task](https://developer.apple.com/documentation/swift/task) · [Image I/O](https://developer.apple.com/documentation/imageio)

## 検証

LinuxでSwiftの構文を確認しました。Simulator と実機では、添付キャンセル、失敗・再送、バックグラウンド後の再開、容量不足、性能を確認予定です。
