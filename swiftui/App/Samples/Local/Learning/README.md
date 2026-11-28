# 短い教材で学び、進捗を記録する

## 試せること

教材3件を読み、必要なら端末の読み上げを使い、選択式の問題に回答します。誤答は再試行でき、正答すると修了日と進捗を端末へ保存します。教材を閉じるかアプリが非アクティブになると読み上げを停止します。

## コードを読む

[LearningSampleView.swift](LearningSampleView.swift) の `LearningSampleView` が教材と進捗を表示し、`LessonView` が読み上げと回答を扱います。`Lesson.samples` が固定教材、`LearningHistory` が教材IDから修了日への対応です。正答を確認してから `LocalRecords` の保存を待ち、成功した時点で進捗を更新します。

## 実装の理由と流用箇所

教材が変わっても修了記録を引き継げるよう、配列位置でなく固定IDを保存します。読み上げはテキストと同じ内容を `AVSpeechSynthesizer` に渡すため、音声ファイルの配布が不要です。教材追加は `Lesson.samples` と安定したIDを更新します。教材を遠隔配信する場合は、データのバージョン、オフライン時に読む範囲、教材の権利を接続先に合わせます。

## 条件と測定

マイク権限、アカウントは不要です。読み上げ音声の入手と品質は端末の設定や日本語音声の状態に依存します。教材本文と回答はオフラインでも使えます。iPhone 17、iOS 27.2.1、Release、教材3件で、回答操作から保存フィードバックまで150 ms以内を目標にします。診断の `save` は結果を記録します。時間は Instruments のメインスレッドとサインポストか画面記録で測定します。読み上げ開始、画面を戻る、アプリを中断する操作を10回繰り返し、音声が画面に残らず、メモリが単調に増えないことを確認します。VoiceOverと最大の文字サイズで回答、再試行、保存結果を確認します。再起動して修了が残るか確かめます。

## 一次資料と検証状況

2026-11-28参照。Xcode 27.2 / iOS SDK 27.2を対象とし、端末の読み上げ、非アクティブ時の停止、アクセシビリティに使います。[AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer) · [SwiftUI ScenePhase](https://developer.apple.com/documentation/swiftui/scenephase) · [Apple HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

教材はサンプル内の文章です。iOSシミュレータ、実機での動作と性能は未測定です。
