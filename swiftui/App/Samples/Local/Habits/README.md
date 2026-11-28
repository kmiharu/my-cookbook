# 習慣の達成日と継続日数を確認する

## 試せること

習慣の目標を変更し、日付を選んで達成を記録します。同じ日の達成を取り消せます。直近7日間と、今日または昨日まで続いている達成日数を確認します。希望する場合は毎日20時の端末内リマインダーを設定し、取り消せます。

## コードを読む

[HabitSampleView.swift](HabitSampleView.swift) の `HabitSampleView` が入口です。選択日からグレゴリオ暦の日付キーを作り、`HabitHistory` の集合で達成状態を管理します。端末のタイムゾーンを使って今日・昨日の境界を求めます。記録済みの日付キーはタイムゾーンを変えても同じ日付のままです。通知は既存記録と独立した操作です。

## 実装の理由と流用箇所

日単位の状態を集合で保存するため、同じ日を重複登録しません。グラフの情報を日付別のテキストでも表示します。達成は最大730件です。複数の習慣を記録する場合は、固定IDから個別の履歴へアクセスし、リマインダーの識別子も分けます。HealthKit連携を追加する場合は、取得する項目、許可の目的、記録がない場合の扱いを定義します。

## 条件と測定

目標と記録には権限、アカウント、通信が不要です。リマインダーを使う場合は端末で通知を許可します。HealthKit連携はありません。iPhone 17、iOS 27.2.1、Release、730件で、記録操作からグラフと集合の表示更新まで200 ms以内を目標にします。画面記録または Instruments で20回の記録と取消を測定します。日をまたぐ状態、数日空いたときの継続日数、タイムゾーン変更、再起動、通知拒否、通知の取消、最大の文字サイズを確認します。

Release用のXcodeスキームの起動引数に `-CatalogLocalStressFixtures` を追加すると、通常の記録と分かれた保存先で昨日からさかのぼる729件を使えます。今日の達成を記録して上限の730件で測ります。

## 一次資料と検証状況

2026-11-28参照。iOS SDK 27.2向けのグラフ、ローカル通知、日付演算に使います。[Swift Charts](https://developer.apple.com/documentation/charts) · [UNCalendarNotificationTrigger](https://developer.apple.com/documentation/usernotifications/uncalendarnotificationtrigger) · [Foundation Calendar](https://developer.apple.com/documentation/foundation/calendar)

iOSシミュレータ、実機での記録と通知の動作、性能は未測定です。
