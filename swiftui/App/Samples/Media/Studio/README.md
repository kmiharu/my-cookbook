# 写真を切り抜き、加工して共有する

- **できること** — 同梱画像または写真を選び、正方形に切り抜き、フィルタを適用し、線を描いて直前の編集を取り消す。完成した JPEG を書き出してシステムの共有機能を開く。
- **読む順番** — [ImageEditingSampleView.swift](ImageEditingSampleView.swift) → [MediaImageProcessor.swift](../MediaImageProcessor.swift)。
- **状態とデータ** — 写真の一時ファイルから編集用 JPEG と小さいプレビューを作る。線はプレビュー内の正規化座標で持ち、編集状態を更新するたびにプレビューを作り直す。書き出しは同じ状態から 1,600 px 以下で再描画する。
- **実装理由** — 写真ピッカーからファイルで受け取り、サイズを確認してから Image I/O で縮小する。描画とエンコードは画面ごとに 1 個の actor と再利用する `CIContext` に隔離する。画面のタスクを世代で更新し、100 ms の待機で加工の連続変更をまとめる。キャンセル済み処理の完了は表示しない。編集中の線は Canvas で応答させる。線を引くボタンも使える。
- **流用時に変える場所** — `ImageEdits` のフィルタ、切り抜き領域、座標・記録上限と `MediaImageProcessor` の透過・色空間・画質・メタデータ方針。正方形に切り抜くと、既存の線も出力領域に合わせて再配置する。
- **外部依存と制約** — 同梱の [StudioSample.png](StudioSample.png) はこのサンプルのために生成した 720 × 540 px の画像。ネットワークやアカウントなしで使える。iCloud 上の写真取得および選択した共有先の動作は端末の設定に依存する。出力は写真を JPEG に再生成したもので、元の EXIF を引き継がない。共有ファイルは一時フォルダへ保存し、次に書き出す際に 24 時間より古いファイルを削除する。
- **性能条件と目標** — iPhone 16・iOS 27.2.1。端末内 12 MP JPEG と 48 MP HEIC を交互に各 10 回読み込む。目標は端末内の写真で選択から表示まで p95 1.2 秒以下、フィルタ指示からプレビュー更新まで p95 350 ms 以下（待機 100 ms を含む）、JPEG 書き出し p95 1 秒以下。入力は 32 MB・1 億画素まで。各画面の CPU 処理は直列。プレビュー長辺 640 px、出力 1,600 px、線は 24 本・1 本 96 点、操作履歴 20 件、24 時間に 20 出力まで。
- **測定方法** — 診断の `load` / `process` / `save` を比較する。画像切替、加工、取消、書き出しを 30 回行い、Time Profiler で UI スレッドと actor を確認し、Allocations で退出後の残存メモリを確認する。容量不足ではエラーを表示し、空きを確保して同じ加工からやり直せることを検証する。
- **出典** — 調査日 2026-11-28。対象 iOS 27.2 SDK。低解像度プレビューとメタデータを絞った出力のため Apple 標準フレームワークを採用。外部コードなし。 [Image I/O](https://developer.apple.com/documentation/imageio) · [Core Image](https://developer.apple.com/documentation/coreimage) · [ShareLink](https://developer.apple.com/documentation/swiftui/sharelink)
- **検証状況** — Swift 6.2.4 Linux で構文と PNG 形式を確認。Simulator と実機動作は未確認。端末で画像の向き、書き出し内容、VoiceOver の描画代替操作、機内モードと iCloud 素材でのキャンセル、空き容量不足を確認する。掲載値は目標。
