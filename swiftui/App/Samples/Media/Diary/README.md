# 写真と音声を添えた日記を保存する

- **できること** — できごとと任意の場所名を書き、カメラ撮影または写真選択、30 秒の音声録音を添えて保存する。履歴から写真の拡大と録音の再生を試せる。削除は確認してから行う。
- **読む順番** — [DiarySampleView.swift](DiarySampleView.swift) → [DiaryStore.swift](DiaryStore.swift) → [SystemCamera.swift](SystemCamera.swift) と [DiaryAudio.swift](DiaryAudio.swift) → [MediaImageProcessor.swift](../MediaImageProcessor.swift)。
- **状態とデータ** — 画面の下書きから actor の `DiaryStore` に保存する。actor が UUID の添付フォルダを作成し、写真、サムネイル、音声を個別に書く。最後に JSON 索引をアトミックに置換する。添付の書き込みや容量確保に失敗したら下書きを維持する。アプリが中断された場合の未参照フォルダは次回の読み込みで回収する。
- **実装理由** — 撮影プレビューの画質、フレーム供給、撮影 UI は iOS の `UIImagePickerController` に任せる。アプリが受け取るのは確定した静止画 1 枚。未処理フレーム用のキューは持たない。選択写真の下処理は actor に渡し、入れ替えや画面離脱をキャンセルとして扱う。録音・再生の停止時には `AVAudioSession` を非アクティブにする。
- **流用時に変える場所** — `DiaryStore` の索引、保存ルート、件数制限とデータモデル。EXIF を保持する必要がある場合は `MediaImageProcessor` の入出力契約を設計し直す。フル解像度保存や独自のプレビューが必要な場合は撮影側の実装を置き換える。
- **外部依存と制約** — 撮影と録音には対応実機、対応する用途の許可が必要。拒否しても文章と写真選択は利用できる。写真ピッカーは iCloud の写真を取得する際に通信が必要な場合がある。場所は手入力。保存はアプリの Application Support に行い、日記の本文・場所・写真・音声は診断へ送らない。アプリ固有の共有先は設定しない。
- **性能条件と目標** — iPhone 16・iOS 27.2.1 で 12 MP と 48 MP の写真各 10 枚を用意する。目標は選択データ受取からプレビュー作成まで p95 1.2 秒以下（端末内の写真）、写真と 30 秒の AAC を添えた保存が p95 0.5 秒以下。入力上限は 32 MB・1 億画素、保存画像は長辺 1,600 px、サムネイルは 480 px、録音は 30 秒・512 KiB、日記は 50 件。履歴は本文だけを読み、詳細で添付を遅延読み込みする。
- **測定方法** — 診断 `capture`（撮影後の縮小、録音の開始結果）、`load`（写真選択全体または履歴）、`save`（添付と索引）と Instruments Allocations を照合する。クラウド取得の時間は画像処理と区別する。撮影と録音の開始・退出を 10 回繰り返してカメラとマイクの使用表示が消え、メモリが増え続けないことを確認する。
- **出典** — 調査日 2026-11-28。対象 iOS 27.2 SDK。Apple 標準の撮影・写真選択・録音 API を採用。外部コードなし。 [UIImagePickerController](https://developer.apple.com/documentation/uikit/uiimagepickercontroller) · [PhotosPicker](https://developer.apple.com/documentation/photosui/photospicker) · [AVAudioRecorder](https://developer.apple.com/documentation/avfaudio/avaudiorecorder)
- **検証状況** — Swift 6.2.4 Linux で構文確認。Foundation の保存処理は一時ディレクトリで、空入力の拒否、保存後の再読込、縮小版・添付の読込、削除を確認した。Simulator と iPhone は未実施。実機で撮影、録音、個別の権限拒否、ホーム移動、音声割り込み、空き容量不足時の保存と再試行を試す。掲載値は目標。
