#!/usr/bin/env bash
set -euo pipefail

mode="${1:-verify}"
if [[ "$mode" != verify && "$mode" != archive ]]; then
  echo "Usage: bash swiftui/ci/ios.sh [verify|archive]" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
revision="$(git rev-parse HEAD)"
expected_revision="${CATALOG_EXPECTED_SHA:-${GITHUB_SHA:-$revision}}"
if [[ -n "${CM_BUILD_ID:-}" ]]; then
  : "${CATALOG_EXPECTED_SHA:?Pass the exact GitHub commit SHA to Codemagic}"
fi
if [[ "$revision" != "$expected_revision" ]]; then
  echo "Checked-out revision differs from the requested revision." >&2
  exit 1
fi

toolchain="$(xcodebuild -version)"
printf '%s\n' "$toolchain"
test "$toolchain" = $'Xcode 27.2\nBuild version 27B52'
test "$(xcodebuild -version -sdk iphoneos SDKVersion)" = 27.2
swift --version

temporary="$(mktemp -d)"
spec=project.yml
release_spec=
trap 'rm -rf -- "$temporary"; if [[ -n "$release_spec" ]]; then rm -f -- "$release_spec"; fi' EXIT
output="$PWD/build/$mode"
mkdir -p "$output"

if [[ "$mode" == archive ]]; then
  : "${CATALOG_BUNDLE_ID:?Set the registered bundle ID}"
  : "${CATALOG_BUILD_NUMBER:?Set the next unused integer build number}"
  if [[ ! "$CATALOG_BUNDLE_ID" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z0-9-]+$ ||
    "$CATALOG_BUNDLE_ID" == com.example.* ||
    ! "$CATALOG_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "Use a registered sample bundle ID and a positive integer build number." >&2
    exit 2
  fi
  grep -Fq 'com.example.cookbook.swiftui' "$spec"
  release_spec="$(mktemp "$PWD/.release-project.XXXXXX")"
  mv "$release_spec" "$release_spec.yml"
  release_spec="$release_spec.yml"
  sed "s/com\.example\.cookbook\.swiftui/$CATALOG_BUNDLE_ID/g" "$spec" > "$release_spec"
  spec="$release_spec"
fi

curl --fail --silent --show-error --location --max-time 90 \
  https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip \
  --output "$temporary/xcodegen.zip"
(
  cd "$temporary"
  printf '%s  %s\n' a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73 xcodegen.zip |
    shasum -a 256 --check
  unzip -q xcodegen.zip
)
"$temporary/xcodegen/bin/xcodegen" generate --spec "$spec" --project .

swift test --package-path Core --scratch-path "$temporary/core"
bash checks/booking/verify.sh
project="$PWD/SwiftUICatalog.xcodeproj"
if [[ "$mode" == verify ]]; then
  rm -rf -- "$output/simulator.xcresult"
  rm -f -- "$output/simulator.xcresult.zip"
  build_status=0
  xcodebuild build -project "$project" -scheme SwiftUICatalog \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.2' \
    -derivedDataPath "$temporary/derived" -resultBundlePath "$output/simulator.xcresult" \
    CODE_SIGNING_ALLOWED=NO "CATALOG_SOURCE_REVISION=$revision" || build_status=$?
  if [[ -d "$output/simulator.xcresult" ]]; then
    ditto -c -k --keepParent "$output/simulator.xcresult" "$output/simulator.xcresult.zip"
  fi
  if [[ "$build_status" == 0 && "${CATALOG_UNSIGNED_ARCHIVE:-0}" == 1 ]]; then
    xcodebuild archive -project "$project" -scheme SwiftUICatalog \
      -configuration Release -destination 'generic/platform=iOS' \
      -derivedDataPath "$temporary/device-derived" \
      -archivePath "$temporary/unsigned/SwiftUICatalog.xcarchive" \
      CODE_SIGNING_ALLOWED=NO "CATALOG_SOURCE_REVISION=$revision"
    test -f "$temporary/unsigned/SwiftUICatalog.xcarchive/Info.plist"
  fi
  if [[ "$build_status" == 0 && "${CATALOG_SIMULATOR_SMOKE:-0}" == 1 ]]; then
    device="$(xcrun simctl list devices available --json | python3 -c '
import json
import sys

devices = json.load(sys.stdin)["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-2"]
print(next(device["udid"] for device in devices if device["name"] == "iPhone 17"))
')"
    python3 - "$device" <<'PYBOOT'
import subprocess
import sys

try:
    subprocess.run(["xcrun", "simctl", "bootstatus", sys.argv[1], "-b"], check=True, timeout=180)
except subprocess.TimeoutExpired:
    raise SystemExit("iOS Simulator did not finish booting within 180 seconds")
PYBOOT
    xcrun simctl install "$device" "$temporary/derived/Build/Products/Debug-iphonesimulator/SwiftUICatalog.app"
    xcrun simctl launch --terminate-running-process "$device" com.example.cookbook.swiftui
    sleep 3
    xcrun simctl io "$device" screenshot "$output/catalog-launch.png"
  fi
  exit "$build_status"
fi

export_options="$temporary/export-options.plist"
xcode-project use-profiles --project "$project" \
  --export-options-plist "$export_options" --archive-method app-store \
  --custom-export-options '{"manageAppVersionAndBuildNumber":false}'
xcode-project build-ipa --project "$project" --scheme SwiftUICatalog --config Release \
  --archive-directory "$temporary/archive" --ipa-directory "$output" \
  --archive-xcargs "CURRENT_PROJECT_VERSION=$CATALOG_BUILD_NUMBER CATALOG_SOURCE_REVISION=$revision DEBUG_INFORMATION_FORMAT=dwarf-with-dsym" \
  --export-options-plist "$export_options"

shopt -s nullglob
archives=("$temporary/archive/"*.xcarchive)
ipas=("$output/"*.ipa)
if [[ ${#archives[@]} != 1 || ${#ipas[@]} != 1 ]]; then
  echo "Expected exactly one archive and one IPA." >&2
  exit 1
fi

archive="${archives[0]}"
ipa="${ipas[0]}"
application_path="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$archive/Info.plist")"
codesign --verify --strict "$archive/Products/$application_path"
unzip -tq "$ipa"
unzip -p "$ipa" 'Payload/*.app/Info.plist' > "$temporary/app-info.plist"

python3 - "$temporary/app-info.plist" "$output/build-receipt.json" "$revision" <<'PY'
import json
import os
import plistlib
import sys
from pathlib import Path

info_path, receipt_path, revision = sys.argv[1:]
with open(info_path, "rb") as file:
    info = plistlib.load(file)

if info["CFBundleIdentifier"] != os.environ["CATALOG_BUNDLE_ID"]:
    raise SystemExit("IPA bundle ID mismatch")
if info["CFBundleVersion"] != os.environ["CATALOG_BUILD_NUMBER"]:
    raise SystemExit("IPA build number mismatch")
if info["CatalogSourceRevision"] != revision:
    raise SystemExit("IPA source revision mismatch")

receipt = {
    "gitCommit": revision,
    "codemagicBuildID": os.environ.get("CM_BUILD_ID"),
    "codemagicAppID": os.environ.get("CM_PROJECT_ID"),
    "bundleID": info["CFBundleIdentifier"],
    "marketingVersion": info["CFBundleShortVersionString"],
    "buildNumber": info["CFBundleVersion"],
    "minimumIOS": info["MinimumOSVersion"],
    "xcodeBuild": "27B52",
}
Path(receipt_path).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
print(json.dumps(receipt, indent=2))
PY

ditto -c -k --keepParent "$archive" "$output/SwiftUICatalog.xcarchive.zip"
