# OpenPencil で共通画面を開く

[カタログのデザイン](catalog.fig) を OpenPencil で開く。レイヤー名、文字、配置、配色を編集できる。`共通画面` にライトとダークのカタログ・案内・診断を収録した。`共通部品と状態` に行、主要操作、読み込み、検索結果なし、失敗、権限拒否、非対応端末を収録した。`狭い幅と文字拡大` には、320 pt 相当の幅で再試行までの案内を確認できる例を置いた。

## SwiftUI との対応

| OpenPencil の要素 | SwiftUI の入口 | 確認すること |
| --- | --- | --- |
| カタログ、タブ、検索、サンプル行 | [`CatalogView` と `CatalogRow`](../App/CatalogView.swift) | `TabView`、`NavigationStack`、`.searchable`、目的と説明、34 pt の目的アイコン。表示対象は [`CatalogEntry`](../App/CatalogEntry.swift) から選ぶ。 |
| サンプル案内 | [`CatalogDetail`](../App/CatalogView.swift) | 試せること、利用条件、接続方式、起動順序。 |
| 診断 | [`DiagnosticsView`](../App/DiagnosticsView.swift) | 記録状況、最新日の計測、書き出し、準備後に表示される共有操作。 |
| 読み込み、検索結果なし、失敗 | [`CatalogView`](../App/CatalogView.swift)、[`FeedSampleView`](../App/Samples/Connected/Feed/FeedSampleView.swift) | `ProgressView`、`ContentUnavailableView`、読み込み中止、再試行。 |
| 権限・端末条件 | [`SpatialSampleView`](../App/Samples/Media/Spatial/SpatialSampleView.swift) | カメラへのアクセス、設定への移動、AR 非対応時の案内。 |
| ライト・ダークの配色 | [AccentColor](../App/Assets.xcassets/AccentColor.colorset/Contents.json) と SwiftUI のシステム色 | アプリのアクセントは色アセットに定義する。デザインには同じ色を sRGB の8ビット値に丸めて反映する。 |

システムの検索欄、タブ、一覧、共有先選択の形状と余白は OS の描画に従う。OpenPencil の共通画面は情報の順序と状態を照合するための例。表示する目的と計測値は例示データで、操作記録は端末の診断画面に表示する。デザイン上の状態例を実機で確認する手順は [画面仕様](../UX-CONTRACT.md) を参照する。

## CLI で内容を確認する

`swiftui/` で実行する。デザインファイルの読み込みと画像の出力には、Node.js と OpenPencil CLI を使う。

```sh
npx --yes @open-pencil/cli@0.17.0 info design/catalog.fig
npx --yes @open-pencil/cli@0.17.0 lint design/catalog.fig --preset accessibility
npx --yes @open-pencil/cli@0.17.0 export design/catalog.fig --page '共通画面' --format png --output /tmp/swiftui-catalog.png
```

作成・読み戻し・レンダーは Linux 上の OpenPencil CLI v0.17.0 で実施した。Noto Sans JP は画面上の和文確認用で、フォントファイルはアプリに組み込まない。CLI のフォント検査は環境によって代替フォントを検出するため、字間や改行が変わる場合はエディタで Noto Sans JP を読み込んで確認する。iOS のテキスト拡大、VoiceOver とシステム操作の検証状態は [検証記録](../docs/VERIFICATION.md) に記載する。

## 参照資料

確認日はいずれも 2026-11-28。

| 対象 | 採用理由 | 資料 |
| --- | --- | --- |
| OpenPencil CLI 0.17.0 | `.fig` の編集と、Linux からの書き出し・点検に用いる。 | [OpenPencil のファイル管理](https://openpencil.dev/user-guide/files) · [CLI Scripting](https://openpencil.dev/developers/cli/scripting) |
| iOS 27.2 SDK | システムの文字拡大、VoiceOver、状態の表示を活用する。 | [Human Interface Guidelines の Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) · [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview) |
| Noto Sans JP | OpenPencil 上で日本語の改行と読みやすさを確認する。 | [Google Fonts](https://fonts.google.com/noto/specimen/Noto+Sans+JP) · [ライセンス（SIL Open Font License 1.1）](https://github.com/notofonts/noto-cjk/blob/main/Sans/LICENSE) |
