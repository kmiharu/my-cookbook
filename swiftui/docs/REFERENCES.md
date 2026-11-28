# 実装や配信を変更するときに読む一次資料

確認日 2026-11-28。Apple の資料は iOS 27.2 / Xcode 27.2、Swift は Xcode 同梱の 6.4 系、GitHub と Codemagic は同日時点の提供仕様が対象です。Apple のオンライン資料は対象 SDK の Availability と合わせて参照します。

| 資料 | このサンプルで使う判断 |
| --- | --- |
| [SwiftUI](https://developer.apple.com/documentation/swiftui) · [Food Truck sample](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app) | ネイティブの検索、ナビゲーション、SwiftUI のデータフローと Preview の参考。 |
| [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) · [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | 文字サイズに追従する書体、状態を文字と記号で伝えること、システムの権限と共有 UI。 |
| [The Swift Programming Language — Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/) · [SwiftUI task](https://developer.apple.com/documentation/swiftui/view/task(priority:_:)) | 画面の寿命とタスクを関連付け、古い処理をキャンセルする。actor でファイル操作や独立した状態を保護する。 |
| [URLSession](https://developer.apple.com/documentation/foundation/urlsession) · [Data and storage](https://developer.apple.com/documentation/technologyoverviews/data-and-storage) | リクエスト・エラー、保存場所、原子的な書き込み。 |
| [PhotosPicker](https://developer.apple.com/documentation/photokit/bringing-photos-picker-to-your-swiftui-app) · [Image I/O](https://developer.apple.com/documentation/imageio) · [Core Image](https://developer.apple.com/documentation/coreimage) | 利用者が選んだ写真を読み込み、元の解像度で展開する前に縮小する。編集処理と書き出しを分ける。 |
| [AVFoundation camera sample](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) · [Vision](https://developer.apple.com/documentation/vision) | カメラの権限とセッション寿命、OCR やバーコード認識の責務。 |
| [HTTP Live Streaming](https://developer.apple.com/streaming/) · [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer) · [AVPlayerLayer](https://developer.apple.com/documentation/avfoundation/avplayerlayer) | HLS の試験配信と再生状態。アイテムの準備完了とレイヤーの表示準備完了を別に測る。 |
| [ARKit](https://developer.apple.com/documentation/arkit) · [Understanding world tracking](https://developer.apple.com/documentation/arkit/understanding-world-tracking) · [RealityKit](https://developer.apple.com/documentation/realitykit) | 対応確認、追跡状態、平面への配置と復帰。 |
| [MapKit](https://developer.apple.com/documentation/mapkit) · [Core Location](https://developer.apple.com/documentation/corelocation) · [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth) | 位置や接続は利用者の操作で開始し、期限と停止を設ける。 |
| [Xcode performance](https://developer.apple.com/documentation/xcode/performance-and-metrics) · [Instruments](https://developer.apple.com/documentation/xcode/instruments) · [MetricKit](https://developer.apple.com/documentation/metrickit) | 計測対象、機種、操作シナリオを固定し、端末内ログと独立した計測値を結び付ける。 |
| [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files) · [Required reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) | アプリ専用ファイルのタイムスタンプと UserDefaults の用途をマニフェストに宣言する。 |
| [GitHub REST Git database](https://docs.github.com/en/rest/git) · [GitHub Actions](https://docs.github.com/en/actions) | 変更ブランチ、対象コミット、Simulator Run と成果物の照合。 |
| [Codemagic YAML](https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/) · [REST API](https://codemagic.io/api/v3/schema/openapi.json) · [CLI tools](https://github.com/codemagic-ci-cd/cli-tools) | ビルド起動と照会、専用署名、IPA の作成とアップロード。 |
| [App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi) · [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) | Apple 処理、対象グループへの配布、実機インストールと調査。 |
| [OpenPencil](https://github.com/open-pencil/open-pencil) · [OpenPencil CLI](https://openpencil.dev/docs/cli) | 編集できるデザインファイルを作り、別の環境でも読み直して検証する。 |

アプリのライブラリは Apple 標準のみ。各 README に再現データと外部配信の出所を記載しています。コードはリポジトリの [ライセンス](../../LICENSE) に従います。ビルド用の [XcodeGen](https://github.com/yonaskolb/XcodeGen) は MIT、デザイン用の [OpenPencil](https://github.com/open-pencil/open-pencil) は上流リポジトリのライセンスを参照します。どちらもアプリには同梱しません。
