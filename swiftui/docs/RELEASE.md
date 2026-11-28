# Simulatorで検証し、TestFlightで配布する

## 使用する環境

| 項目 | 採用した値 | 根拠 |
| --- | --- | --- |
| 実機の基準 | 正式版 iOS 27.2.1 | 2026-11-09公開。測定時の機種とOSのパッチ番号も記録する。[Apple security releases](https://support.apple.com/en-us/100100) |
| Xcode・SDK | Xcode 27.2（27B52）、iOS SDK 27.2 | 正式版のAppleツールチェーンを使う。[Xcode 27.2 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes) |
| Swift・Deployment Target | Xcode同梱のSwift 6.4、Swift 6言語モード、iOS 27.2 | SDKと同じマイナーバージョンを最低動作条件にする。Swift 6モードで並行処理の検査を行う。[Xcodeの対応OSとSwift](https://developer.apple.com/xcode/system-requirements/) |
| Codemagic | `mac_mini_m2`、`xcode: '27.2'`、Simulator iPhone 17 / iOS 27.2 | 対応するビルドイメージとSimulatorが掲載されている。共有イメージが更新されたときは実測版を再確認する。[Codemagicイメージ](https://docs.codemagic.io/specs-macos/xcode-27-2/)、[バージョン更新方針](https://docs.codemagic.io/specs/xcode-update-policy/) |
| GitHub Actions | `xcode-27`、`/Applications/Xcode_27.2.app` | 公開リポジトリで使えるarm64標準ランナー。イメージ20261123.0387に対応するiOS SDK、Simulator、端末定義がある。[標準ランナー](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[イメージリリース](https://github.com/actions/runner-images/releases/tag/xcode-27-arm64/20261123.0387)、[搭載ツール](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) |
| Xcodeプロジェクト生成 | XcodeGen 2.44.1 | CIが公開のmacOS ZIPを取得し、SHA-256を照合する。配布アプリの依存には含まれない。MIT。[リリース](https://github.com/yonaskolb/XcodeGen/releases/tag/2.44.1)、[ライセンス](https://github.com/yonaskolb/XcodeGen/blob/2.44.1/LICENSE) |

上記の公式資料は2026-11-28確認。CIは実行時にもXcodeのビルド番号とSDKのバージョンを照合し、Swiftの実バージョンをログに残す。Linuxでは `swift test --package-path swiftui/Core` で純Swiftのテストを実行する。署名不要のSimulatorコンパイルもApple向けSDKを備えたmacOSで実行する。

## 既存カメラアプリの配信経路を参照する

既存カメラアプリの運用文書と検証台帳を2026-11-28に確認した。記録上は GitHub Actions から Codemagic REST API v3 を使用し、Xcode 26.0 の署名不要Simulatorビルドを検証している。APIによる作成と、その後に改良した判定処理での照会は別実行。照会結果には対象SHAの一致と必要な手順の成功が記録されている。署名・TestFlight配布は運用文書上の検証範囲外。

今回も、確定SHAの照合、Macビルドの明示起動、ビルドIDでの照会、結果から生ログや短期ダウンロードURLを除外する運用を採用した。カタログでは専用のCodemagic App、Bundle ID、App Store Connect登録、署名ファイル、テスターグループを使う。カメラ側の認証設定はカメラのGitHub Environmentにあることが運用文書で確認できた。公開リポジトリへの資格情報の移動や、既存グループへのカタログの追加は配信手順に含めない。

## サンプル専用の配信設定を準備する

1. Apple Developerチームで使うBundle IDを決める。Appleの `GET /v1/bundleIds?filter[identifier]=…` と `GET /v1/apps?filter[bundleId]=…` で専用登録の有無を確認する。対象がなければBundle IDは `POST /v1/bundleIds` で登録できる。AppleのApps APIにはアプリレコードの作成操作が掲載されていないため、新規アプリレコードはApp Store Connectの「アプリを追加」を使用する。管理権限とApple Developer Programの状態を確認する。[Bundle IDs API](https://developer.apple.com/documentation/appstoreconnectapi/bundle-ids)、[Apps API](https://developer.apple.com/documentation/appstoreconnectapi/apps)、[新しいアプリを追加](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
2. Codemagicの `GET /api/v3/user/apps` でアクセス可能な対象を探す。登録がなければ、公式Applications APIで公開GitHubリポジトリを `POST https://api.codemagic.io/apps` で追加できる。この登録APIはプレビュー扱い。使用するApp IDと実際のリポジトリを登録結果で照合する。可能であれば専用チーム内に作成する。[Applications API](https://docs.codemagic.io/rest-api/applications/)、[v3 OpenAPI](https://codemagic.io/api/v3/schema/openapi.json)
3. 専用のApp Store Connect APIキーをCodemagicに連携し、参照名を `cookbook-swiftui-testflight` にする。対象Bundle IDのApp Store配信用プロファイルを `cookbook-swiftui-app-store`、プロファイルと対応するApple Distribution証明書を `cookbook-swiftui-distribution` として登録する。確認したREST v3スキーマにはこれらの連携や署名ファイルを登録する操作が掲載されていないため、初回設定はCodemagicの公式Team settingsを使用する。以降のビルド起動と取得はAPIで行う。[iOS署名](https://docs.codemagic.io/yaml-code-signing/signing-ios/)、[App Store Connect連携](https://docs.codemagic.io/yaml-publishing/app-store-connect/)
4. カタログ専用の内部テスターグループを作成する。初回は手動で対象ビルドを追加できるグループにし、対象テスターとビルドを照合できるようにする。内部テスターにはApp Store Connect上のユーザー権限が必要。外部テスターが必要なら別の専用グループを作り、必要な説明、連絡先、Beta App Reviewを準備する。[内部テスターの追加](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/)、[外部テスターの招待](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)、[Beta Groups API](https://developer.apple.com/documentation/appstoreconnectapi/beta-groups)

`swiftui/project.yml` の `com.example.cookbook.swiftui` はSimulator用の仮ID。配信用スクリプトは登録済みの `CATALOG_BUNDLE_ID` を一時的なプロジェクト設定に入れ、証明書とプロファイルを適用する。Codemagic APIトークンとAppleの秘密鍵は、運用環境の秘密管理から取得する。GitHubでAPIを操作する場合も、公開リポジトリの成果物や環境設定値に秘密値を保存しない。

## 確定したコミットをビルドする

1. GitHubの変更ブランチまたはタグと、その完全なコミットSHAを確定する。macOSでの再現はリポジトリ直下から `bash swiftui/ci/ios.sh verify` を実行する。GitHub Actions の push 検証では Core と予約の検査、iPhone 17 Simulator コンパイル、実機 SDK の署名なし Release アーカイブを確認する。手動実行の `workflow_dispatch` は Simulator の起動と画像も検証する。macOS では `CATALOG_UNSIGNED_ARCHIVE=1 CATALOG_SIMULATOR_SMOKE=1 bash swiftui/ci/ios.sh verify` で同じ条件を再現できる。
2. Codemagicでは `swiftui-simulator` がCoreテストとSimulatorコンパイル、`swiftui-testflight` がCoreテストと署名済みIPAの作成・アップロードを行う。配信時は対象バージョンの登録済みビルド番号をApple側で照会し、次に利用する整数の番号を選ぶ。
3. CodemagicのアプリIDと実行中のビルドを確認する。GitHub上のSHAをAPI overrideとして渡し、実行時のcheckoutと照合する。参照するブランチが起動の前後に進んだ場合はビルドを中止する。必要に応じてAPIの `branch` を `tag` に替える。

以下はBash、curl、jqを使う例。環境変数は運用環境で設定する。2026-11-28に公式v3スキーマを取得し、認証ヘッダー名と下記の要求・応答構造を確認した。CodemagicとApp Store Connectの専用MCPはこの作業環境のツール一覧で確認できなかった。[Builds API](https://docs.codemagic.io/rest-api/builds/)、[v3 OpenAPI](https://codemagic.io/api/v3/schema/openapi.json)

```bash
set -o pipefail
cm() {
  curl --silent --show-error --fail --max-time 30 \
    --header @<(printf 'x-auth-token: %s\n' "$CODEMAGIC_API_TOKEN") "$@"
}
api=https://codemagic.io/api/v3

# 使用するアプリと直近のビルドIDを確認する。複数ページは page を指定する。
cm "$api/user/apps" | jq '{current_page,total_pages,data:[.data[]|{id,name,archived,last_build_id}]}'
cm --get "$api/teams/$CODEMAGIC_TEAM_ID/builds" --data-urlencode "app_id=$CODEMAGIC_APP_ID" \
  | jq '{cursor,data:[.data[]|{id,status,branch,tag,sha:.commit.hash,workflow:.workflow.id}]}'

# 署名なしの起動例。ブランチ名と完全なSHAを別々に渡す。
body=$(jq -n --arg ref "$CATALOG_GIT_REF" --arg sha "$CATALOG_EXPECTED_SHA" '{
  workflow_id:"swiftui-simulator",branch:$ref,environment:{variables:{CATALOG_EXPECTED_SHA:$sha}}
}')
cm --request POST --header 'Content-Type: application/json' --data-binary "$body" \
  "$api/apps/$CODEMAGIC_APP_ID/builds" | jq -er '.data.id'

# TestFlightアップロード用。上のSimulator用POSTから置き換えて使用する。
body=$(jq -n --arg ref "$CATALOG_GIT_REF" --arg sha "$CATALOG_EXPECTED_SHA" \
  --arg bundle "$CATALOG_BUNDLE_ID" --arg number "$CATALOG_BUILD_NUMBER" '{
  workflow_id:"swiftui-testflight",branch:$ref,
  environment:{variables:{CATALOG_EXPECTED_SHA:$sha,CATALOG_BUNDLE_ID:$bundle,CATALOG_BUILD_NUMBER:$number}}
}')
cm --request POST --header 'Content-Type: application/json' --data-binary "$body" \
  "$api/apps/$CODEMAGIC_APP_ID/builds" | jq -er '.data.id'

# POSTが返したIDを記録してから照会する。
cm "$api/builds/$CODEMAGIC_BUILD_ID" | jq '.data | {
  id,app_id,workflow,status,sha:.commit.hash,app_store_connect_status,
  artifacts:[.artifacts[]|{name,type,size_in_bytes}]}'
cm "$api/builds/$CODEMAGIC_BUILD_ID/actions?page_size=100&page=1" \
  | jq '{current_page,total_pages,data:[.data[]|{type,status,has_test_results}]}'
```

成功判定ではApp ID、workflow、checkout SHA、必須ステップの成功を照合する。POSTの結果がタイムアウトなどで不明なときは、起動時刻と同じブランチ・workflowのビルドをAPIで確認し、見つかったIDを照会する。同じ要求を再送するとビルドが重複し得る。個人アカウントでチーム一覧を利用できない場合は `user/apps` の `last_build_id` と該当ビルドを照会する。結果の照会は再ビルドを必要としない。

調査用成果物はSimulatorの `simulator.xcresult.zip`、配信用の `.ipa`、dSYMを含む `SwiftUICatalog.xcarchive.zip`、`build-receipt.json`。保護された保管先に必要なものを保存する。Codemagicの公開v3スキーマはビルドステップと成果物を取得できるが、生ログ取得用のエンドポイントは掲載していない。Codemagic側のステップログとApple側の検証結果は別の記録として扱う。

## Apple側の処理を確認して対象グループへ配布する

1. Codemagicの公開処理ステップでアップロード成功を確認する。`build-receipt.json` のBundle ID、バージョン、ビルド番号を控える。
2. 専用App IDから `GET /v1/builds` を照会する。`filter[app]`、`filter[version]`（ビルド番号）、`filter[preReleaseVersion.version]`（バージョン）で絞り込み、該当するAppleビルドIDと `processingState` を確認する。Apple側の処理完了は `VALID` で判定する。処理失敗や輸出コンプライアンスの保留がある場合は、その状態とAppleからの通知を記録する。暗号化に関する申告は使用状況とAppleの質問に基づいて判断する。[List builds](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds)、[ビルドのステータス](https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-build-statuses/)、[輸出コンプライアンス](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
3. `GET /v1/apps/{appId}/betaGroups` でカタログ専用グループを照合する。内部テスター向けなら `isInternalGroup` が true であることを確認する。その `POST /v1/betaGroups/{groupId}/relationships/builds` に `{"data":[{"type":"builds","id":"APPLE_BUILD_ID"}]}` を送ってビルドを追加し、`GET /v1/betaGroups/{groupId}/builds` で反映を確認する。App Store Connect APIはAppleの手順に従って短命JWTで認証する。公開リンクや外部配布を選ぶ場合は、Apple側で該当ビルドのBeta App Reviewが完了していることを確認する。[Apple API認証](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)、[ビルドをグループに追加](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betagroups-_id_-relationships-builds)、[Beta App Review](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betaappreviewsubmissions)
4. `GET /v1/builds/{buildId}/buildBetaDetail` と対象グループのテスターを照合する。配信済みの記録には対象グループと配信日時を残す。TestFlightに表示されることと端末で起動できることは、インストール後に別々に確認する。[Build Beta Details](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds-_id_-buildbetadetail)

Codemagic YAMLの `submit_to_testflight` は、対象グループを上記の手順で選ぶため `false`。署名済みIPAのApp Store Connectアップロードは有効。既存グループで「自動配信」が設定されている場合は、アップロード前に専用アプリの対象グループと配信範囲を照合する。今回の配信操作はTestFlightまで。

以下は配信前の照会例。JWTはAppleの手順に沿って生成し、`ASC_JWT` に一時的に渡す。

```bash
asc() {
  curl --silent --show-error --fail --max-time 30 \
    --header @<(printf 'Authorization: Bearer %s\n' "$ASC_JWT") "$@"
}
apple=https://api.appstoreconnect.apple.com/v1
asc --get "$apple/builds" \
  --data-urlencode "filter[app]=$ASC_APP_ID" \
  --data-urlencode "filter[preReleaseVersion.version]=$CATALOG_MARKETING_VERSION" \
  | jq '[.data[]|{id,number:.attributes.version,state:.attributes.processingState}]'
asc "$apple/apps/$ASC_APP_ID/betaGroups" \
  | jq '[.data[]|{id,name:.attributes.name,internal:.attributes.isInternalGroup,
    allBuilds:.attributes.hasAccessToAllBuilds,publicLink:.attributes.publicLinkEnabled}]'
```

## iPhoneでインストールして診断を書き出す

1. 招待を受けたApple AccountでTestFlightを開く。対象アプリ名とバージョン・ビルド番号を確認し、インストールして起動する。
2. 一覧でサンプルを検索し、案内から開く。サンプルのREADMEにある測定条件で操作し、開始時刻、機種、iOSの版、通信条件、結果を記録する。
3. カタログの診断画面で書き出す。iOSの共有シートから「ファイルに保存」またはインストール済みのGoogle Driveを選び、自分で保存先を指定する。共有した診断と記録した操作を関連付ける。

## 配信台帳

| 段階 | 照合する情報 | 現在の状態 |
| --- | --- | --- |
| Simulatorビルド | GitHub SHA、Codemagic IDまたはGitHub Actions run ID、CoreテストとXcode結果 | CI設定を作成。実行結果は検証記録を参照 |
| 署名済みビルド | GitHub SHA、Codemagic ID、バージョン・ビルド番号、IPA・アーカイブ | 専用Codemagic Appと署名設定の確認待ち |
| アップロード | 同一IPAのCodemagic公開ステップ、Apple側の受領 | 未実施 |
| Apple処理完了 | AppleビルドID、処理状態、保留事項 | 未確認 |
| 対象テスターへ公開 | AppleビルドID、カタログ専用グループID、公開日時 | 未配信 |
| 実機インストールと起動 | 機種、OS、バージョン・ビルド番号、診断共有 | 未確認 |
| サンプルの実機検証 | サンプル別の条件、回数、計測値、診断 | 未確認 |

GitHub は CLI とコネクタを利用できた。Codemagic と App Store Connect の照会 API はこの環境から到達できたが、資格情報のバインドがなく HTTP 401 となった。専用登録やテスターの現状は未確認。必要となるのは、専用Codemagic AppのIDと権限、Apple Developerチームと専用Bundle IDの登録、App Store ConnectアプリのApple ID、署名・アップロード用の安全な設定、対象テスターグループ。秘密値は共有せず、承認済みサービス側で設定する。
