# 空き時間を選んで、予約・日時変更・取消を試す

## コードの入口

[BookingSampleView.swift](BookingSampleView.swift) の `BookingSampleView.send` → [BookingModel.swift](BookingModel.swift) の `BookingState.apply` を読みます。

## 状態とデータの流れ

日本時間で今日から14日間の枠を表示します。操作 ID と更新前のリビジョンを作り、予約・変更・取消を1回のファイル更新にまとめます。更新を保存した直後に応答が途切れるケースでは、同じ操作 ID で再試行して結果を取得できます。

## 実装を選んだ理由

空き枠チェック、再送キー、楽観的な競合検知を UI から独立した値型で定義しています。入力の二重操作は画面で抑止し、モデルで同じ操作 ID の重複を除外します。保存後の応答エラーを切り替えられるため、失敗表示と実際の保存状態が異なる場合を確認できます。

## 他のアプリで置き換える箇所

`BookingSchedule` の固定枠を施設の在庫サービスに置き換えます。`BookingState.apply` の検証、操作 ID、リビジョン、予約状態をサーバー側の1トランザクションで管理し、期限や再照会を設計します。

## 依存と制約

再現用に30分の枠を1日2〜3件生成し、保持できる予約は1件、再送IDは直近24件です。施設への接続や予約通知はありません。テストは実際の時間帯によって今日の空きがなくなる場合に備え、翌日も使います。

## 性能目標と測定方法

iPhone 17、iOS 27.2.1、機内モード、翌日〜13日後から30回、予約・変更・取消を繰り返します。P95は900 ms以下（再現待ち650 ms込み）を目標とし、診断の `.process` の経過時間と Instruments の Time Profiler で測ります。保存後エラーの連打・取消のキャンセル後に予約枠とファイルの件数を確認します。目標値です。

## 公式資料と出典

Appleの Calendar、DatePicker、Data のアトミック保存（確認日 2026-11-28、iOS SDK 27.2）。時間帯を固定した日付計算、日付選択、再送記録と予約の保存に採用しました。外部コードの取り込みはありません。 [Calendar](https://developer.apple.com/documentation/foundation/calendar) · [DatePicker](https://developer.apple.com/documentation/swiftui/datepicker) · [Data.WritingOptions](https://developer.apple.com/documentation/foundation/data/writingoptions)

## 検証

LinuxでSwiftの構文と [予約モデルの回帰検査](../../../../checks/booking/verify.sh) を実行しました。不正枠、同じ操作の再送、二重予約、異なる内容を持つ同一ID、古いリビジョン、取消、JSONの復元、初回起動と容量上限時の旧データ保持を確認しました。Simulator と実機の画面操作、容量不足、性能は確認予定です。
