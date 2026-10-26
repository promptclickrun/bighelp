#!/bin/zsh
# The App Store screenshot set from the real app on a real, isolated Hermes host.
# Usage: Scripts/AppStoreScreenshots.sh <hermes from a throwaway checkout> <bighelp plugin folder> <output folder>
# Uses its own iPhone 17 Pro Max (6.9"), iPad Pro 13" and iPhone Duo simulators, erased first
# (BIGHELP_STORE_DEVICES="iphone", "ipad" or "duo" takes just one set; the Duo needs its iOS 27.1
# runtime and gives the cover screen's set, as its simulator can't be opened),
# with the status bar at 9:41, full signal and a full battery.
set -euo pipefail
hermes=$1 plugin=$2 output=$3
repo=${0:A:h:h}
derived=${BIGHELP_STORE_DERIVED:-/tmp/bighelp-store-dd}
port=${BIGHELP_STORE_PORT:-9333}
typeset -A devices=(iphone com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
                    ipad com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
                    duo com.apple.CoreSimulator.SimDeviceType.iPhone-Duo)
# Newest first: a runtime can be for one device only (iOS 27.1 runs just the Duo).
runtimes=($(xcrun simctl list runtimes -j | python3 -c "import json,sys; print(' '.join(reversed([r['identifier'] for r in json.load(sys.stdin)['runtimes'] if r['platform']=='iOS' and r['isAvailable']])))"))
# 9:41 on Apple's day, written in UTC for this Mac's time zone.
clock=$(python3 -c "from datetime import datetime, timezone; print(datetime(2007,1,9,9,41).astimezone().astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")
mkdir -p "$output"
for kind in ${=BIGHELP_STORE_DEVICES:-iphone ipad}; do
  name=bighelp-store-$kind
  udid=$(xcrun simctl list devices -j | python3 -c "import json,sys; print(next((d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='$name'), ''))")
  if [[ -z $udid ]]; then
    for runtime in $runtimes; do udid=$(xcrun simctl create $name ${devices[$kind]} $runtime 2>/dev/null) && break; done
  fi
  [[ -n $udid ]] || { echo "$kind: no runtime for ${devices[$kind]}"; exit 1; }
  xcrun simctl shutdown $udid 2>/dev/null || true
  xcrun simctl erase $udid
  xcrun simctl boot $udid
  xcrun simctl status_bar $udid override --time $clock --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState discharging --batteryLevel 100
  xcodebuild build-for-testing -project "$repo/Bighelp.xcodeproj" -scheme Bighelp -destination "id=$udid" \
    -derivedDataPath "$derived" -quiet
  # A fresh host for each device, so each set shows one run of each job.
  log=$(mktemp -t bighelp-store-host)
  python3 "$repo/Scripts/AppStoreScreenshotHost.py" --hermes "$hermes" --plugin "$plugin" --port $port > $log 2>&1 &
  host=$!
  trap "kill $host 2>/dev/null; rm -f $log" EXIT
  until grep -q '"address"' $log; do kill -0 $host || { cat $log; exit 1 }; sleep 1; done
  zone=$(python3 -c "import json,sys; print(json.loads(open('$log').read().splitlines()[-1])['time_zone'])")
  TEST_RUNNER_BIGHELP_STORE_SCREENSHOTS="$output" TEST_RUNNER_BIGHELP_STORE_HOST=127.0.0.1:$port \
  TEST_RUNNER_BIGHELP_STORE_TZ=$zone TEST_RUNNER_BIGHELP_STORE_PREFIX=$kind xcodebuild test-without-building -project "$repo/Bighelp.xcodeproj" \
    -scheme Bighelp -destination "id=$udid" -derivedDataPath "$derived" \
    -only-testing:BighelpUITests/AppStoreScreenshotUITests || echo "$kind: some screens failed"
  kill $host; wait $host 2>/dev/null || true
  rm -f $log
  # Code mode's home for the Code poster: its own UI test on the demo projects. The shot holds
  # session cards, not chats.
  if [[ $kind != duo ]]; then
    code=$(mktemp -d -t bighelp-store-code)
    TEST_RUNNER_BIGHELP_CODE_MODE_EVIDENCE=$code TEST_RUNNER_BIGHELP_CODE_MODE_APPEARANCE=light \
      xcodebuild test-without-building -project "$repo/Bighelp.xcodeproj" -scheme Bighelp -destination "id=$udid" \
      -derivedDataPath "$derived" \
      -only-testing:BighelpUITests/CodeModeUITests/testSendsStartSessionsBackToBackAndMenuSwitchesModes \
      || echo "$kind: Code mode failed"
    cp "$code/02-two-sessions.png" "$output/$kind-12-code.png" 2>/dev/null || echo "$kind: no Code mode shot"
    rm -rf $code
  fi
  xcrun simctl shutdown $udid
done
ls "$output"
