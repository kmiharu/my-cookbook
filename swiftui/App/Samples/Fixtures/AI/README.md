# 質問を入力し、応答を少しずつ受け取って中断する

## コードの入口

[AISampleView.swift](AISampleView.swift) の `AISampleView.generate` と `FixtureAIStream.AsyncIterator.next` を読みます。

## 状態とデータの流れ

質問を端末へ保存し、AsyncSequence から返る文字列を1行ずつ表示します。中断・失敗・完了時に部分応答と状態を保存します。再試行時は同じ履歴項目を更新します。

## 実装を選んだ理由

定型文の AsyncSequence を消費側のタスクが駆動するため、無制限のバッファやバックグラウンドの生産タスクを持ちません。画面を離れるかバックグラウンドに移ると、次のチャンクを待つタスクをキャンセルします。

## 他のアプリで置き換える箇所

`FixtureAIStream` を実際の推論ストリームに置き換えます。APIを利用する場合は接続先、認証、最大応答長・待機時間、SSEの行境界、キャンセルの伝播、送信データの扱いを明記します。モデルを端末に置く場合も同様に最大コンテキスト長、対応機種やモデルのライセンスを定めます。

## 依存と制約

入力は300文字、履歴は12件までです。再現ストリームは4チャンクを各300 ms間隔で返します。定型文は言葉に応じて3種類から選びます。アカウント、モデル、API、推論は使いません。診断には質問と応答を含めません。

## 性能目標と測定方法

iPhone 17、iOS 27.2.1、機内モード、履歴12件で30回操作します。再現上の初回表示はP95で550 ms以内、中断操作から更新停止まで150 ms以内が目標です。診断の `.load` は最初の文字列がアプリに到達した時点で、描画完了は画面収録のフレームで別に計ります。割り込み後にタスクが残らないことを Instruments の Swift Concurrency で確認します。目標値です。

## 公式資料と出典

AppleとSwiftの AsyncSequence、タスクのキャンセル（確認日 2026-11-28、Swift 6.4）。区切られた応答の逐次表示と中断に採用しました。外部コードの取り込みはありません。 [AsyncSequence](https://developer.apple.com/documentation/swift/asyncsequence) · [The Swift Programming Language: Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)

## 検証

LinuxでSwiftの構文を確認しました。Simulator と実機では、部分表示、途中エラー、中断、再試行、履歴復元、性能を確認予定です。
