# 商品を調べて比較する

## 試せること

架空の商品10,000件を検索します。分類、並べ替え、50件単位の前後移動、最大3件の価格比較、検索条件の保存と復元を試せます。例として「本」で検索し、価格が低い順に並べて商品を2件選び、「比較」を開きます。

## コードを読む

[SearchSampleView.swift](SearchSampleView.swift) の `SearchSampleView` から読みます。入力と分類・並べ替えから `SearchCondition` を組み立て、同じ条件を検索と保存に使います。`ProductIndex` は最初の検索で再現用データを生成します。その後は同じ配列を使い、画面は現在のページだけを行として渡します。

## 実装の理由と流用箇所

検索の実行はアクターに任せます。入力の更新や画面移動で `.task(id:)` が古い検索を取り消します。走査は128件ごとにキャンセルを確認し、結果を画面に反映する直前にも確認します。並べ替えは価格が同じときに商品番号で順序を確定します。比較は検索条件を変えても最大3件を保持します。

外部の商品を扱う場合は `ProductIndex` をサーバー側の検索とページ取得に切り替えます。商品番号、キャッシュ上限、並べ替え順、キャンセル後に結果を適用しない条件を接続先に合わせます。入力した検索語は条件保存を選んだときに端末のアプリ領域へ保存されます。

## 条件と測定

追加権限、アカウント、通信は不要です。iPhone 17、iOS 27.2.1、Release ビルドを測定条件とします。初回に生成を含む10,000件の検索が500 ms以内、条件を20回変更した後も定常検索の95パーセンタイルが200 ms以内を目標にします。診断の `process` の成功時間は、入力待ち250 msを除いた最初の検索呼び出しから結果の適用までです。古い検索のキャンセル時間は別に読みます。高速連打、入力消去、該当なし、50件ごとの移動、比較3件上限、保存後の再起動を試します。画面の出入りを10回繰り返し、Instruments の Allocations で画面ごとの配列が蓄積しないか確認します。

## 一次資料と検証状況

2026-11-28参照。Xcode 27.2 / Swift 6.4を対象とし、検索UIと画面寿命に合わせた処理を確認するために使います。[SwiftUI searchable](https://developer.apple.com/documentation/swiftui/view/searchable(text:placement:prompt:)) · [SwiftUI task(id:)](https://developer.apple.com/documentation/swiftui/view/task(id:name:priority:file:line:_:)) · [Swift Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)

検索と比較は内蔵の再現用データを使います。LinuxのSwift 6.2.4で検索アクターを単独実行し、10,000件、価格の降順、該当なし、キャンセルを確認しました。iOSシミュレータ、実機での操作と性能は未測定です。
