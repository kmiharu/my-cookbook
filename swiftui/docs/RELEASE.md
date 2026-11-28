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

## GitHub ActionsからTestFlightの配信を進める

[SwiftUI TestFlight](../../.github/workflows/swiftui-testflight.yml) は手動実行専用。既定ブランチへワークフローを取り込んだ後に実行できる。ワークフロー自身は信頼済みのブランチから実行し、配信するコードは入力で別途指定する。並行起動を避けるため、このアプリの配信操作はGitHub Actions内で直列化する。

GitHubの専用Environment `swiftui-testflight` に次を設定する。Codemagicへ連携する署名・アップロード用の資格情報と、ここでApple APIを呼ぶための資格情報は、各サービスの秘密管理で扱う。

| 設定 | 名前と用途 |
| --- | --- |
| Environment secrets | `CODEMAGIC_API_TOKEN`、`ASC_PRIVATE_KEY`。AppleのチームAPIキーの未加工の `.p8` を後者に設定する。 |
| Environment variables | `CODEMAGIC_TEAM_ID`、`CODEMAGIC_APP_ID`、`ASC_APP_ID`、`ASC_BETA_GROUP_ID`、`CATALOG_BUNDLE_ID`、`ASC_KEY_ID`、`ASC_ISSUER_ID`。CodemagicのチームAPIで対象リポジトリとの一致を確認する。 |
| Apple側 | カタログ専用の内部テスターグループを手動選択方式で設定し、対象テスターを登録する。アプリに自動配信グループがある場合は、意図しない配布を防ぐためワークフローが停止する。 |

1. `start` に配信元の完全なref、SHA、バージョン、未使用のビルド番号を渡す。GitHubの実ref、Codemagicのリポジトリ、Appleのアプリと内部グループを照合してから署名・アップロードを起動する。実行結果に出る `codemagicBuildID` を控える。バージョンは配信する `swiftui/project.yml` の値と揃える。
2. `status` に同じSHA、バージョン、ビルド番号と `codemagicBuildID` を渡す。必要なら `wait_seconds` で待機する。Codemagicのビルド、アップロード、Apple側の処理、内部テストの状態を別々に確認する。
3. `ready_to_distribute` を確認し、同じ情報で `distribute` を実行する。Apple側の関連付けを再照会する。 `group_assigned` はグループへの追加済み。 `available_for_internal_testing` はAppleが内部テスト中と報告した状態。端末へのインストールは別途確認する。

GitHub CLIでの起動例。 `WORKFLOW_REF` は配信ワークフローを取り込んだ信頼済みブランチ、 `RELEASE_REF` は配信するブランチまたはタグの完全ref。

```bash
gh workflow run swiftui-testflight.yml --ref "$WORKFLOW_REF" \
  -f operation=start -f ref="$RELEASE_REF" -f sha="$RELEASE_SHA" \
  -f version="$VERSION" -f build_number="$BUILD_NUMBER"

gh workflow run swiftui-testflight.yml --ref "$WORKFLOW_REF" \
  -f operation=status -f sha="$RELEASE_SHA" -f version="$VERSION" \
  -f build_number="$BUILD_NUMBER" -f codemagic_build_id="$CODEMAGIC_BUILD_ID" -f wait_seconds=1800

gh workflow run swiftui-testflight.yml --ref "$WORKFLOW_REF" \
  -f operation=distribute -f sha="$RELEASE_SHA" -f version="$VERSION" \
  -f build_number="$BUILD_NUMBER" -f codemagic_build_id="$CODEMAGIC_BUILD_ID"
```

## ローカルから同じ配信コマンドを使う

Python 3.10以上、Git、OpenSSLを使う。Environment variablesと同じ環境変数を設定し、 `CODEMAGIC_API_TOKEN` を秘密管理から渡す。 `ASC_KEY_PATH` に秘密管理から取得したチームAPIキーの `.p8` ファイルを指定する。スクリプトはOpenSSLで短命JWTを生成し、処理待ち中に更新する。秘密値、APIの生レスポンス、署名付き成果物URLは出力しない。

```bash
python3 swiftui/ci/testflight.py start --ref "$RELEASE_REF" --sha "$RELEASE_SHA" \
  --version "$VERSION" --build-number "$BUILD_NUMBER"

python3 swiftui/ci/testflight.py status --sha "$RELEASE_SHA" \
  --version "$VERSION" --build-number "$BUILD_NUMBER" \
  --codemagic-build-id "$CODEMAGIC_BUILD_ID" --wait 1800

python3 swiftui/ci/testflight.py distribute --sha "$RELEASE_SHA" \
  --version "$VERSION" --build-number "$BUILD_NUMBER" --codemagic-build-id "$CODEMAGIC_BUILD_ID"
```

- `start` が返答を受け取れなかった場合は、出力に示したリリースラベルでCodemagicのチームビルドを検索し、ビルドIDを取得して `status` を使う。起動要求の自動再送は行わない。同じ版・ビルド番号の既存ビルドを見つけた場合も、このビルドIDから再開する。一度失敗した配信用ビルドの再ビルドは次の番号を使う。配信の起動を直列化する場合はGitHub Actionsに集約する。
- `status` の待機上限は3600秒。待機時間切れは終了コード3、明確な失敗やApple側の保留は1。 `apple_blocked` の場合は `internalBetaState` を確認し、必要な暗号化申告などをApple側で済ませてから再照会する。
- `distribute` は対象ビルドの関連付けがある場合に同じ追加を送らない。返答が不明な場合もAppleの関連付けを読み直す。再実行時は照会から始まるため、ビルドを作り直す必要はない。
- CodemagicはIPA、dSYM付きアーカイブ、 `build-receipt.json` を作成する。配信コマンドの結果と一緒にGit SHA、CodemagicビルドID、バージョン、ビルド番号、AppleビルドID、対象グループを保管する。

GitHub Actionsのpush検証は、Coreと予約の検査、iPhone 17 Simulatorコンパイル、実機SDKの署名なしReleaseアーカイブを実行する。Simulator起動を含むmacOSでの再現は `CATALOG_UNSIGNED_ARCHIVE=1 CATALOG_SIMULATOR_SMOKE=1 bash swiftui/ci/ios.sh verify`。Codemagicの署名なし検証は `swiftui-simulator` ワークフローに完全SHAを渡して起動する。

Codemagicの `swiftui-testflight` はIPAをApp Store Connectへアップロードする。対象グループの追加は配信コマンドで行うため、YAMLの `submit_to_testflight` は `false`。その運用ではCodemagicのApple処理状況が空の場合があるため、コマンドは必要に応じてCodemagicの配信ステップを確認し、Apple側でアプリ・iOS・バージョン・ビルド番号を照合する。 [Codemagic REST v3](https://codemagic.io/api/v3/schema/openapi.json) · [Publishing to App Store Connect](https://docs.codemagic.io/yaml-publishing/app-store-connect/) · [Apple API認証](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests) · [List builds](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds) · [Build Beta Details](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds-_id_-buildbetadetail) · [対象グループにビルドを追加](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betagroups-_id_-relationships-builds)

## iPhoneでインストールして診断を書き出す

1. 招待を受けたApple AccountでTestFlightを開く。対象アプリ名とバージョン・ビルド番号を確認し、インストールして起動する。
2. 一覧でサンプルを検索し、案内から開く。サンプルのREADMEにある測定条件で操作し、開始時刻、機種、iOSの版、通信条件、結果を記録する。
3. カタログの診断画面で書き出す。iOSの共有シートから「ファイルに保存」またはインストール済みのGoogle Driveを選び、自分で保存先を指定する。共有した診断と記録した操作を関連付ける。

## 配信台帳

| 段階 | 照合する情報 | 現在の状態 |
| --- | --- | --- |
| Simulatorビルドと起動 | GitHub SHA、GitHub Actions run ID、CoreテストとXcode結果 | GitHub Actions で成功。[検証記録](VERIFICATION.md) |
| 署名なし Release アーカイブ | GitHub SHA、Xcode iPhoneOS SDK、GitHub Actions run ID | GitHub Actions で成功。[検証記録](VERIFICATION.md) |
| 署名済みビルド | GitHub SHA、Codemagic ID、バージョン・ビルド番号、IPA・アーカイブ | 専用Codemagic Appと署名設定の確認待ち |
| アップロード | 同一IPAのCodemagic公開ステップ、Apple側の受領 | 未実施 |
| Apple処理完了 | AppleビルドID、処理状態、保留事項 | 未確認 |
| 対象テスターへ公開 | AppleビルドID、カタログ専用グループID、公開日時 | 未配信 |
| 実機インストールと起動 | 機種、OS、バージョン・ビルド番号、診断共有 | 未確認 |
| サンプルの実機検証 | サンプル別の条件、回数、計測値、診断 | 未確認 |

GitHub は CLI とコネクタを利用できた。Codemagic と App Store Connect の照会 API はこの環境から到達できたが、資格情報のバインドがなく HTTP 401 となった。専用登録やテスターの現状は未確認。必要となるのは、専用Codemagic AppのIDと権限、Apple Developerチームと専用Bundle IDの登録、App Store ConnectアプリのApple ID、署名・アップロード用の安全な設定、対象テスターグループ。秘密値は共有せず、承認済みサービス側で設定する。
