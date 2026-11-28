# AR でブロックを置く・星を探して遊ぶ

- **できること** — AR モードで机や床を探し、画面中央へのレイキャストでブロックを最大 6 個置く。配置と追跡のリセットや中断後の再開を試す。ミニゲームでは 3 × 3 のタイルを開いて 3 個の星を見つける。完了後は新しい配置で遊べる。
- **読む順番** — [SpatialSampleView.swift](SpatialSampleView.swift) の `SpatialSampleView`、`SpatialModel`、`ARStage.Coordinator`、`TileSearchGame` の順。
- **状態とデータ** — 対応判定とカメラ許可のあとでセッションを開始する。フレームから追跡状態と時刻だけを参照し、追跡状態によって配置ボタンを制御する。AR 退出、タブ移動、アプリの非アクティブ化で停止してアンカーを解放する。復帰後は明示的に開始できる。実行中のシステム割り込みからの復帰は追跡と配置をリセットする。
- **実装理由** — 水平面の検出に限定し、RealityKit の小さな共有ボックスメッシュを生成する。テクスチャ、カメラバッファの蓄積、モデル取得の通信が不要。毎フレーム UI タスクを追加せず、状態の変化と一秒ごとの集計で表示を更新する。VoiceOver から配置ボタン、追跡状態、配置数と通常のゲームにアクセスできる。
- **流用時に変える場所** — セッションの構成、`place(in:)` のレイキャスト種類、モデルと材質の準備、アンカー数、復帰時の座標保持方針。永続配置が必要ならワールドマップの保存・権限・再ローカライズを設計する。
- **外部依存と制約** — AR は `ARWorldTrackingConfiguration.isSupported` の対応端末とカメラ許可が必要。非対応、拒否時はゲームで遊べる。ネットワーク、アカウント、素材ライブラリは不要。配置できない場合は十分な明るさと表面の模様がある水平面で試す。
- **性能条件と目標** — iPhone 16・iOS 27.2.1、屋内で模様のある机または床、アンカー 6 個で 10 分。目標は安定時のカメラフレーム更新 50 fps 以上、Metal System Trace で描画の p95 が 25 ms 以下、10 分で高い熱状態に達する場合は時刻と条件を記録し、モデル数・描画負荷を見直す。`frameInterval` は 5 秒ごとにサンプルした AR フレーム間隔で、GPU の描画時間は別計測。保存する熱状態は高温側の分類と件数のみ。画像・位置・カメラ姿勢は記録しない。
- **測定方法** — 初回追跡、水平面へのレイキャスト、暗所や急な動きで `trackingLimited`、通常状態への復帰、リセットを確認する。中断・復帰と退出を 10 回繰り返し、カメラの使用表示とメモリの収束を確認する。診断と Instruments の Time Profiler・Metal System Trace・メモリ結果を開始・復帰時刻で突き合わせる。
- **出典** — 調査日 2026-11-28。対象 iOS 27.2 SDK。追跡と描画に標準フレームワークを採用。外部モデル、外部コードなし。 [ARKit](https://developer.apple.com/documentation/arkit) · [RealityKit](https://developer.apple.com/documentation/realitykit) · [ARSessionDelegate](https://developer.apple.com/documentation/arkit/arsessiondelegate)
- **検証状況** — Swift 6.2.4 Linux で構文確認。Simulator と実機は未実施。Simulator では非対応案内、ゲームの完了、再開と VoiceOver を試す。追跡状態、配置、熱、描画性能と権限の復帰は iPhone で検証する。掲載値は目標。
