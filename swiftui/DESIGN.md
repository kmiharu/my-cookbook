---
version: alpha
name: SwiftUI サンプル
colors:
  primary: '#006C67'
  primary-dark: '#64DDD0'
typography:
  system:
    fontFamily: 'iOS system font'
rounded:
  sample-icon: '8px'
omitted:
  - section: spacing
    reason: '画面の余白と行高は SwiftUI の標準コンポーネントに従うため。'
components:
  sample-row: {}
  sample-icon-light:
    textColor: '{colors.primary}'
    rounded: '{rounded.sample-icon}'
  sample-icon-dark:
    textColor: '{colors.primary-dark}'
    rounded: '{rounded.sample-icon}'
  sample-guide: {}
  diagnostics: {}
  state-message: {}
---

# SwiftUI サンプルの画面設計

## Overview

iPhone で操作を試す人は、まず「見る・聴く」「作る・編集する」のような目的から入口を見つける。各行の青緑の記号と操作の説明で、目的が近いサンプルも見分けられる。案内に進むと、できる操作と必要な利用条件を確認してから起動できる。技術名や実装理由を知りたい開発者とローカル LLM は、各サンプルの README を参照する。

操作と診断は日本語で表示する。想定する場面は、日本語を読む開発者やテスターが iPhone でサンプルを試し、必要に応じて診断データを共有する作業。地域を対象とする実サービスへの購入や予約は、個別の接続先と運用条件に従う。画面の操作契約は [UX-CONTRACT.md](UX-CONTRACT.md) を参照する。

## Colors

青緑を主要操作と選択中の項目に使う。行の記号には青緑の薄い背景を添える。背景、面、区切り、本文と補足は iOS のシステム設定に従う。読み込み、失敗、権限拒否などは短い見出しと案内文で区別し、記号を補助に使う。ライトとダークで情報の優先度を保つ。

OpenPencil の面色は比較用の近似値。アクセントの実行時の定義とデザインの対応は [design/README.md](design/README.md) に示す。

## Typography

iOS 標準の文字と Dynamic Type を使う。画面タイトルは標準のナビゲーションタイトル、一覧の名前は `headline`、操作の説明は `subheadline` を基準にする。日本語の改行は表示側に任せ、長い説明が複数行になっても全文を読めるようにする。OpenPencil では日本語の行送りを確認するために Noto Sans JP を使用する。アプリは iOS 標準の和文表示を使用する。

## Layout

標準のタブとナビゲーションを画面の外枠に使う。端末のセーフエリアとキーボードは SwiftUI に任せる。一覧は横スクロールを必要としない1列とする。案内と診断は、縦に読む順序で操作と条件を配置する。カタログ行のタイトルと説明は、行の高さを固定せずに積み上げる。操作と条件の詳細を読む際、スクロールで全文に到達できることを端末で確認する。

## Elevation & Depth

一覧の区切りとシステムのグループ背景で、見出しと行の所属を表す。画面間の移動、シート、共有先選択は iOS 標準の階層に従う。

## Shapes

一覧の目的アイコンは 34 pt 四方、角の半径は 8 pt。アイコンの背景は装飾で、タップ対象は行全体。検索欄、行、ボタンの外形と押下フィードバックは SwiftUI の標準スタイルに従う。

## Components

| 画面・部品 | 表示方針 |
| --- | --- |
| タブと一覧 | サンプルと診断を1タップで切り替える。目的・操作・技術名を検索の手がかりにする。 |
| サンプル案内 | 目的、実際に試せること、利用条件、起動操作の順に読む。接続方式を起動前に表示する。 |
| 診断 | 記録状況と書き出しを分ける。共有先の選択に iOS の共有機能を使う。 |
| 状態 | `ProgressView` や `ContentUnavailableView` と文言で状態を示す。続行できるときは再試行や設定を開く操作を添える。 |
| アイコン | 実装では SF Symbols を使う。説明を伴う記号は装飾として扱い、単独で操作する記号には VoiceOver 名を付ける。 |
| 動き | 標準の画面遷移と進捗表示を使う。再生や AR の動きは各サンプルの操作に従う。 |

ボタンの文言は `写真を選ぶ`、`再試行`、`診断を書き出す` のように、押した結果が分かる動詞を使う。「キャンセル」は入力やシートを戻す操作、「中止」は実行中の処理を止める操作に使う。操作と結果は VoiceOver でも確認できるよう表示する。
