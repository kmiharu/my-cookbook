# 写真つきの投稿を下書きから公開する流れを試す

## コードの入口

[SocialSampleView.swift](SocialSampleView.swift) の `SocialSampleView` → `SocialSeedFeed.page`、`saveDraft`、`publish`、`react` を読みます。

## 状態とデータの流れ

初回に保存済み下書き、端末内の投稿、反応 ID を復元します。下書きは明示的な保存で永続化します。再現用フィードは8件ずつ読み込み、ローカル投稿を先頭に並べます。投稿エラー時は草稿を残します。成功時は投稿追加と草稿のクリアを1回の更新にまとめます。

## 実装を選んだ理由

ページ読み込みと書き込みに独立したタスクを持たせ、フィードの待ち時間に下書きの入力を続けられます。写真は共有の ImageIO パイプラインで縮小します。反応は投稿 ID の集合で管理します。

## 他のアプリで置き換える箇所

`SocialSeedFeed.page` にページカーソルを受け取る取得処理を置き、`publish` と `react` を認証済み API に接続します。下書きからサーバーの投稿 ID を確定できる再送キーを使い、反応の競合とオフライン再送を決めます。

## 依存と制約

再現用フィード36件、端末内投稿12件、本文500文字、JPEG 320 px・128 KBを上限とします。32 MiB・1億画素以下の写真をシステムの写真選択で指定します。公開先への接続や同期はありません。端末内の記録と診断用メトリクスの保存先は別です。

## 性能目標と測定方法

iPhone 17、iOS 27.2.1、12 MP HEIFの写真を添付し、投稿12件と再現データ36件を表示します。ページ操作のP95目標は400 ms以下（250 ms待機込み）。再現ページの読み込みと投稿を各30回繰り返し、診断の `.load` と `.save` を確認します。Allocationsで一覧を往復した後にオリジナル写真のメモリが残っていないことを調べます。目標値です。

## 公式資料と出典

Appleの SwiftUI List、PhotosPicker、Data のアトミック保存（確認日 2026-11-28、iOS SDK 27.2）。一覧の行管理、システム写真選択、投稿と草稿の同時更新に採用しました。外部コードの取り込みはありません。 [List](https://developer.apple.com/documentation/swiftui/list) · [PhotosPicker](https://developer.apple.com/documentation/photosui/photospicker) · [Data.WritingOptions](https://developer.apple.com/documentation/foundation/data/writingoptions)

## 検証

LinuxでSwiftの構文を確認しました。Simulator と実機では、草稿が再起動後に復元されること、失敗時に内容を維持すること、全ページ読み込み、反応、添付、タスク中断、書き込みエラー、性能を確認予定です。
