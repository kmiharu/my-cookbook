# 予定を入れ、タスクを完了し、一覧を共有する

## 試せること

予定を作ってカレンダーから確認し、完了と未完了を切り替えます。未来の予定は端末のリマインダーを登録して取り消せます。予定の一覧をシステムの共有機能へ渡せます。「共有リストの競合を試す」では、2台から編集したときの競合を再現します。下書きを入力し、別端末の追加を再現してから「リストに反映」を押すと、下書きを保ったまま最新版を読み直せます。

## コードを読む

[ScheduleSampleView.swift](ScheduleSampleView.swift) の `ScheduleSampleView` が画面の入口です。`ScheduledTask` は日時、完了状態と通知識別子を持ちます。カレンダーで指定した日に一致する予定を表示し、`LocalRecords` の保存が成功してから表示を更新します。`ListConflictDemo` は手元の版番号と再現先の版番号を比較します。

## 実装の理由と流用箇所

通知は予定ごとの固定IDで登録し、予定を完了すると保留中の通知を取り消します。ロック画面に入力文が出ないよう、通知本文は固定文です。予定のタイトルを共有する場合は、利用者自身がiOSの共有先を指定します。共有同期を実装する場合は `ListConflictDemo` のコミット判定をサーバーのリビジョンまたは ETag 検証へ置き換えます。版の比較と書き込みを同時に行い、競合時は下書きを保ってから再取得します。

## 条件と測定

追加アカウントやサーバーは不要です。リマインダーには通知の許可が必要です。競合は画面で再現し、再起動でリセットされます。共有シートの転送先は端末に入っているアプリに依存します。

iPhone 17、iOS 27.2.1、Release、200件の予定と同日50件を測定条件とし、日付選択から一覧更新まで150 ms以内が目標です。Instruments の Time Profiler と画面記録で日付を20回切り替えて測定します。再起動、リマインダー登録と取消、権限拒否、集中モード、時刻直前での設定、保存失敗と再試行を確認します。競合デモでは両方の変更が残ることを確かめます。

Release用のXcodeスキームの起動引数に `-CatalogLocalStressFixtures` を追加すると、通常の記録と分かれた保存先に、4日分の計200件（1日50件）を初期データとして使えます。

## 一次資料と検証状況

2026-11-28参照。iOS SDK 27.2を対象とし、通知、日付入力、利用者による共有に使います。[User Notifications](https://developer.apple.com/documentation/usernotifications) · [DatePicker](https://developer.apple.com/documentation/swiftui/datepicker) · [ShareLink](https://developer.apple.com/documentation/swiftui/sharelink)

実際の共有同期は未接続です。iOSシミュレータ、実機での動作と性能は未測定です。
