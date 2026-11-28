# 商品を選び、カートと購入の状態を試す

## コードの入口

[ShoppingSampleView.swift](ShoppingSampleView.swift) の `ShoppingSampleView` → `productDetail` → `updateQuantity` → `checkout` の順に読みます。

## 状態とデータの流れ

4つの商品を表示し、端末内にお気に入り、数量、購入の再現履歴を保存します。支払いを試すと確認画面を出し、失敗・中断時はカートを残します。再現成功時に履歴追加とカート削除を同じ書き込みで確定します。

## 実装を選んだ理由

円の価格と数量は整数で合計します。送信中は操作を無効にし、保存時にもカートが変わっていないことを検証します。保存に失敗した場合はディスクを変更せず、次の操作で再試行できます。

## 他のアプリで置き換える箇所

商品、在庫と価格を API から取得する場合は、購入を確定するサーバーが最終の金額と在庫を検証します。`checkout` の再現処理を、商品の種類に応じた決済手段に置き換えます。デジタル商品向けに StoreKit を使う場合は StoreKit Testing と sandbox で別途トランザクションを検証します。

## 依存と制約

商品4件、在庫は0〜8、履歴は12件を上限とします。アカウントや実決済、StoreKit sandbox との接続はありません。決済情報や配送先を入力する必要はありません。

## 性能目標と測定方法

iPhone 17、iOS 27.2.1、機内モードで商品3種類を最大数量まで入れます。確認完了から再現結果のP95を1.1秒以下（800 ms待機込み）、数量変更のP95を150 ms以下とします。診断の `.process` と `.save` を確認し、短時間の連打・30回の購入後も履歴が1操作ずつ増えることを調べます。目標値です。

## 公式資料と出典

Appleの SwiftUI Stepper、Foundation FormatStyle、StoreKit Testing（確認日 2026-11-28、iOS SDK 27.2）。数量と円の表示に標準部品を採用し、実取引を追加する場合の検証先を確認しました。外部コードの取り込みはありません。 [Stepper](https://developer.apple.com/documentation/swiftui/stepper) · [FormatStyle](https://developer.apple.com/documentation/foundation/formatstyle) · [StoreKit Testing](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode)

## 検証

LinuxでSwiftの構文を確認しました。Simulator と実機では、お気に入り保存、在庫0、数量変更、確認シートのキャンセル、失敗・再試行、購入中断、履歴永続化、性能を確認予定です。
