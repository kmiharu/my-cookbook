# 動画と音声を再生する

- **できること** — Apple の HLS テスト動画と音声、または同梱の確認音を選び、再生、一時停止、シーク、停止、再試行を試す。背景へ移動すると通信とプレーヤー項目を解放し、戻ったら同じ画面で再生を指示して直前の位置から再開する。
- **読む順番** — [PlaybackSampleView.swift](PlaybackSampleView.swift) → [PlaybackModel.swift](PlaybackModel.swift)。
- **状態とデータ** — `AVPlayerItem.status`、`AVPlayer.timeControlStatus`、`AVPlayerLayer.isReadyForDisplay`、終端通知から UI の状態と計測を更新する。監視は試行ごとの世代で識別し、タイムアウトや停止時に observer と item を解放する。シークは連続要求のうち最新だけを反映する。
- **実装理由** — `AVPlayer` の適応ビットレート選択を用い、HLS で希望上限 3 Mbps・720p を提示する。上限はプレイヤーへの希望値。ネットワークからの読み込みをアプリ独自に先取りしない。初回再生が 20 秒で始まらなければ終了して再試行を促す。再バッファ中は停止や一時停止が可能。
- **流用時に変える場所** — `PlaybackSource.url` と配信仕様、音声セッション、再生制御、字幕・バックグラウンド再生・認証の要否。配信テスト素材は自分が運用権限を持つ素材へ差し替える。
- **外部依存と制約** — Apple の公開 Example Playlist へ HTTPS 接続する。適応の選択、ネットワークと CDN の可用性に依存する。サンプルは配信映像を同梱・複製しない。使用範囲は Apple 提供のサンプル配信で再生を試すこと。同梱の [PlaybackTone.wav](PlaybackTone.wav) は合成した 4 秒の 16 kHz モノラル PCM でオフライン利用できる。 [Apple HLS のサンプル](https://developer.apple.com/streaming/examples/) · [マスタープレイリスト](https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8)
- **計測の定義** — 開始点はボタン操作でアイテムを設定する直前。 `ready` はアイテムの `readyToPlay`。 `play` は再生クロックが最初に `playing` へ遷移した時点。 `firstFrame` は `AVPlayerLayer.isReadyForDisplay` の最初の通知までの時間で、合成後に画面へ表示された時刻を計測するには Instruments や外部計測を使う。 `rebuffer` は最初の再生後に自動待機へ入った区間。初回ロードとユーザーの一時停止は再バッファ回数へ加えない。 `seek` は最新の要求から完了コールバックまで。
- **性能条件と目標** — iPhone 16・iOS 27.2.1、540p/60 fps を含む Apple HLS、Wi‑Fi 30 Mbps/RTT 30 ms 以下でコールド開始を 10 回測定する。目標は最初の映像の表示準備 p95 3 秒以下、10 分再生の再バッファ合計 3 秒未満。次に 2 Mbps、RTT 180 ms と切断 15 秒で再バッファ、通信復帰、再試行を確認する。遷移・シーク・退出を 10 サイクル行い、Allocations と VM Tracker で退出後の常駐メモリが連続増加せず、初回終了時から 15 MiB 以内に収束することを目標にする。Time Profiler と Energy Log で 10 分間と退出後の負荷を比較する。
- **出典** — 調査日 2026-11-28。対象 iOS 27.2 SDK。再生状態と表示準備を区別するため AVFoundation の item/player/layer を使用。外部コードなし。 [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer) · [AVPlayerLayer](https://developer.apple.com/documentation/avfoundation/avplayerlayer) · [HTTP Live Streaming](https://developer.apple.com/streaming/)
- **検証状況** — Linux で Swift 6.2.4 構文確認、Apple のマスターと 960 × 540 のメディアプレイリストを取得。取得したバリアントは 100 セグメント、計 600 秒。WAV の PCM ヘッダーも確認。Simulator と iPhone での再生・測定は未実施。掲載値は目標。
