# 支出を記録し、予算の残りを見る

## 試せること

円の金額、日付、分類を入力して支出を記録します。毎月の予算を更新し、月ごとの合計、予算残高、分類別グラフを確認します。履歴の行から、対象を確認して削除できます。

## コードを読む

[ExpenseSampleView.swift](ExpenseSampleView.swift) の `ExpenseSampleView` が入口です。`YenAmount.parse`（[CatalogCore](../../../../Core/Sources/CatalogCore/YenAmount.swift)） が入力を正規化して整数に変換し、`Expense` と `Expenses` が支出と予算を表します。`LocalRecords` は保存の成功を待ってからデータを公開します。表示中の月の支出から合計と分類別の値を求めます。

## 実装の理由と流用箇所

円は整数で保持し、丸め誤差を避けます。入力は前後の空白を除き、全角数字を正規化した後、1〜1,000,000の十進整数として検証します。小数点、符号、桁区切り、空欄を拒否します。1,000件を上限にするため、合計は64ビットの整数範囲内です。日付は端末のカレンダーで日単位に扱います。複数通貨を扱う場合は金額と通貨を一緒に持ち、月境界を業務のタイムゾーンで定義します。件数や更新頻度が増えたら、ファイル全体の書き換えをクエリ可能な永続化方式に切り替えます。

## 条件と測定

追加権限、アカウント、通信は不要です。金融機関との接続はありません。iPhone 17、iOS 27.2.1、Release、1,000件を対象とし、保存開始から端末内の更新まで200 ms以内を目標にします。診断の `save` の成功時間、Time Profiler での集計、Allocations での月切替を確認します。履歴は最初に30件を表示して、追加操作ごとに30件を開きます。日付境界、月初と月末、全角数字、金額上限、小数、容量不足、削除の取消、再起動を試します。グラフの数値は同じ分類のテキスト一覧でも確認できます。

Release用のXcodeスキームの起動引数に `-CatalogLocalStressFixtures` を追加すると、通常の記録と分かれた保存先で999件から始まります。1件保存して上限の1,000件で測ります。

## 一次資料と検証状況

2026-11-28参照。Xcode 27.2 / iOS SDK 27.2向けの通貨表示、グラフ、日付比較に使います。[Foundation FormatStyle](https://developer.apple.com/documentation/foundation/formatstyle) · [Swift Charts](https://developer.apple.com/documentation/charts) · [Foundation Calendar](https://developer.apple.com/documentation/foundation/calendar)

LinuxのSwift 6.2.4で金額入力14ケースの自動テストに合格しました。iOSシミュレータ、実機での操作と性能は未測定です。
