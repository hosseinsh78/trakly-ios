#!/usr/bin/env bash
# The macOS steps of the iOS CI (docs/specs/phase10-apps-and-stores.md §K5, §K7, §L4), called by the public mirror's
# .github/workflows/ios.yml from the repository root:
#
#   bash ios/tools/ci.sh xcode                       select the pinned Xcode, print the toolchain and the runtimes
#   bash ios/tools/ci.sh xcodegen                    the pinned XcodeGen (SHA-256 checked), then `xcodegen generate`
#   bash ios/tools/ci.sh build                       build-for-testing (Debug, Simulator, ad hoc signing)
#   bash ios/tools/ci.sh device <name> [runtime]     create a Simulator of that device type; prints its UDID
#   bash ios/tools/ci.sh server                      the local panel stand-in on 127.0.0.1:8000 (background)
#   bash ios/tools/ci.sh unit <udid>                 the XCTest unit tests (TraklyTests)
#   bash ios/tools/ci.sh ui <udid> <light|dark> <flows|shots|large|ios17> <device-label>
#                                                    the XCUITest pass on that device and appearance; screenshots
#                                                    exported to build/shots/<device-label>-<appearance>-<pass>/
#
# Every xcodebuild log is kept under build/logs/ for the artifact. No secret is read anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build"
DERIVED="$BUILD/DerivedData"
PROJECT="$ROOT/ios/Trakly.xcodeproj"
mkdir -p "$BUILD/logs" "$BUILD/results" "$BUILD/shots"

pretty() {
  if command -v xcbeautify >/dev/null 2>&1; then xcbeautify --renderer github-actions; else cat; fi
}

case "${1:-}" in
  xcode)
    if [ -d "${XCODE_APP:-}" ]; then
      sudo xcode-select -s "$XCODE_APP"
    else
      echo "::warning::${XCODE_APP:-XCODE_APP} is missing; installed:" && ls -d /Applications/Xcode*.app
      exit 1
    fi
    xcodebuild -version
    swift --version
    xcrun simctl list runtimes
    ;;

  xcodegen)
    ZIP="$RUNNER_TEMP/xcodegen.zip"
    curl -fsSL -o "$ZIP" "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
    echo "${XCODEGEN_SHA256}  $ZIP" | shasum -a 256 -c -
    rm -rf "$RUNNER_TEMP/xcodegen" && unzip -q "$ZIP" -d "$RUNNER_TEMP/xcodegen"
    "$RUNNER_TEMP/xcodegen/xcodegen/bin/xcodegen" --version
    "$RUNNER_TEMP/xcodegen/xcodegen/bin/xcodegen" generate --spec "$ROOT/ios/project.yml" --project "$ROOT/ios"
    ;;

  build)
    set -o pipefail
    xcodebuild build-for-testing \
      -project "$PROJECT" -scheme Trakly -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$DERIVED" \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES COMPILER_INDEX_STORE_ENABLE=NO \
      2>&1 | tee "$BUILD/logs/build.log" | pretty
    ;;

  device)
    NAME="$2"
    RUNTIME="${3:-}"
    if [ -z "$RUNTIME" ]; then
      RUNTIME="$(xcrun simctl list runtimes -j | node -e '
        const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
        const ios = data.runtimes.filter((r) => r.platform === "iOS" && r.isAvailable).sort((a, b) => a.version.localeCompare(b.version, undefined, { numeric: true }));
        process.stdout.write(ios.length ? ios[ios.length - 1].identifier : "");')"
    fi
    TYPE="$(xcrun simctl list devicetypes -j | NAME="$NAME" node -e '
      const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const found = data.devicetypes.find((d) => d.name === process.env.NAME);
      process.stdout.write(found ? found.identifier : "");')"
    if [ -z "$TYPE" ] || [ -z "$RUNTIME" ]; then
      echo "::error::no device type «$NAME» or no iOS runtime" >&2
      xcrun simctl list devicetypes >&2
      exit 1
    fi
    xcrun simctl create "Trakly $NAME" "$TYPE" "$RUNTIME"
    ;;

  server)
    LOG="$BUILD/logs/panel-server.log"
    nohup node "$ROOT/ios/TraklyUITests/Panel/server.mjs" --port 8000 > "$LOG" 2>&1 &
    for _ in $(seq 1 50); do
      if curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then
        echo "panel stand-in up"
        exit 0
      fi
      sleep 0.2
    done
    cat "$LOG"
    echo "::error::the panel stand-in did not start" >&2
    exit 1
    ;;

  unit)
    UDID="$2"
    xcrun simctl boot "$UDID" || true
    xcrun simctl bootstatus "$UDID" -b
    set -o pipefail
    xcodebuild test-without-building \
      -project "$PROJECT" -scheme Trakly -configuration Debug \
      -destination "id=$UDID" -derivedDataPath "$DERIVED" \
      -only-testing:TraklyTests \
      -resultBundlePath "$BUILD/results/unit.xcresult" \
      2>&1 | tee "$BUILD/logs/unit.log" | pretty
    ;;

  ui)
    UDID="$2"
    APPEARANCE="$3"
    PASS="$4"
    LABEL="$5"
    xcrun simctl boot "$UDID" || true
    xcrun simctl bootstatus "$UDID" -b
    xcrun simctl ui "$UDID" appearance "$APPEARANCE"
    xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
    case "$PASS" in
      flows) ONLY="-only-testing:TraklyUITests/FlowTests" ;;
      shots) ONLY="-only-testing:TraklyUITests/ScreenshotTests" ;;
      large) ONLY="-only-testing:TraklyUITests/ScreenshotTests/testTheShellAtALargeTextSize" ;;
      ios17) ONLY="-only-testing:TraklyUITests/FlowTests/testLaunchSignInAndTabs -only-testing:TraklyUITests/FlowTests/testComposerReaderReviewAndTheOrderForm -only-testing:TraklyUITests/FlowTests/testClearingShopData" ;;
      *) echo "unknown pass $PASS" >&2; exit 2 ;;
    esac
    RESULT="$BUILD/results/$LABEL-$APPEARANCE-$PASS.xcresult"
    rm -rf "$RESULT"
    set +e
    # shellcheck disable=SC2086
    TEST_RUNNER_TRAKLY_APPEARANCE="$APPEARANCE" TEST_RUNNER_TRAKLY_DEVICE="$LABEL" TEST_RUNNER_TRAKLY_PASS="$PASS" \
    xcodebuild test-without-building \
      -project "$PROJECT" -scheme Trakly -configuration Debug \
      -destination "id=$UDID" -derivedDataPath "$DERIVED" \
      $ONLY -resultBundlePath "$RESULT" \
      2>&1 | tee "$BUILD/logs/$LABEL-$APPEARANCE-$PASS.log" | pretty
    STATUS=${PIPESTATUS[0]}
    set -e
    OUT="$BUILD/shots/$LABEL-$APPEARANCE-$PASS"
    mkdir -p "$OUT"
    xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" || true
    if [ -f "$OUT/manifest.json" ]; then
      # Name every PNG after its attachment (manifest.json maps the exported files to the attachment names).
      OUT="$OUT" node -e '
        const fs = require("fs"), path = require("path");
        const dir = process.env.OUT;
        const manifest = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
        for (const test of manifest) {
          for (const item of test.attachments || []) {
            const from = path.join(dir, item.exportedFileName);
            const name = (item.suggestedHumanReadableName || item.exportedFileName).replace(/[^A-Za-z0-9._-]+/g, "-");
            if (fs.existsSync(from) && name.endsWith(".png")) fs.renameSync(from, path.join(dir, name));
          }
        }'
    fi
    ls "$OUT" | head -80
    exit "$STATUS"
    ;;

  *)
    echo "usage: ci.sh xcode|xcodegen|build|device|server|unit|ui" >&2
    exit 2
    ;;
esac
