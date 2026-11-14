#!/bin/zsh
# Builds the Debug Mac app (Mac Catalyst) and runs it on the demo data under its own
# bundle ID (app.loopdy.mobile.dev-<name>), so several copies can run side by side
# without sharing app data, and none of them touches the real app's.
#
# Usage: Scripts/mac-dev-run.sh [--name NAME] [--no-build] [-- app arguments…]
#        Scripts/mac-dev-run.sh [--name NAME] --quit | --clean
#
#   --name NAME   The copy's name (letters, digits, dashes; default "dev"). Each name has its own
#                 DerivedData, app copy and sandbox container.
#   --no-build    Launch the last build again.
#   --quit        Quit this name's running copy.
#   --clean       Quit it and delete its build, copy, sandbox container and Launch Services entry.
#   -- …          Extra launch arguments, for example
#                 -- -loopdy.settings.nerd-mode YES -loopdy.demo.appearance dark
#
# Prints the running copy's pid on the last line of output. Its output goes to
# $BIGHELP_MAC_DEV_DIR/<name>/app.log (default /tmp/bighelp-mac-dev).
#
# The copy is signed ad hoc with a sandbox-only entitlements file (written below), because app
# groups, pushes and keychain groups need provisioning profiles. So, in a dev copy:
#   - The keychain is unavailable (no application identifier), so nothing a host sign-in saves
#     survives; demo mode doesn't need it.
#   - Pushes, sealed alerts, the shared app group and the notification extension are left out.
#   - The loopdy:// links and Shortcuts stay with the real app: the copy drops its URL types and
#     App Intents metadata.
set -euo pipefail
repo=${0:A:h:h}
root=${BIGHELP_MAC_DEV_DIR:-/tmp/bighelp-mac-dev}
# Resolved (/tmp is /private/tmp), so the running copy can be found by its path.
root=${root:A}
name=dev build=1 action=run
extra=()
while (( $# )); do
  case $1 in
    --name) name=$2; shift ;;
    --no-build) build=0 ;;
    --quit) action=quit ;;
    --clean) action=clean ;;
    --) shift; extra=("$@"); break ;;
    *) print -u2 "Unknown option: $1 (see the top of $0)"; exit 2 ;;
  esac
  shift
done
[[ $name =~ '^[a-z0-9][a-z0-9-]*$' ]] || { print -u2 "--name takes lowercase letters, digits and dashes."; exit 2; }

bundle_id=app.loopdy.mobile.dev-$name
work=$root/$name
derived=$work/DerivedData
app=$work/Bighelp.app
log=$work/app.log
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

running_pids() { pgrep -f "^$app/Contents/MacOS/" || true; }

quit_copy() {
  local pids=($(running_pids))
  (( ${#pids} )) || return 0
  kill $pids 2>/dev/null || true
  for _ in {1..50}; do
    (( ${#$(running_pids)} )) || return 0
    sleep 0.1
  done
  kill -9 $(running_pids) 2>/dev/null || true
}

case $action in
  quit) quit_copy; exit 0 ;;
  clean)
    quit_copy
    [[ -d $app ]] && $lsregister -u "$app" 2>/dev/null || true
    rm -rf "$work"
    # The sandbox keeps the copy's data (preferences, caches, files) under its bundle ID only.
    rm -rf ~/Library/Containers/$bundle_id ~/Library/Application\ Scripts/$bundle_id
    print "Removed $work and the $bundle_id container."
    exit 0 ;;
esac

if (( build )); then
  mkdir -p "$work"
  print "Building into $derived…"
  xcodebuild build -project "$repo/Bighelp.xcodeproj" -scheme BighelpCatalyst -configuration Debug \
    -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO -quiet
  # The build product carries the real app's ID; keep Launch Services from offering it for that ID.
  $lsregister -u "$derived/Build/Products/Debug-maccatalyst/Bighelp.app" 2>/dev/null || true
fi
built=$derived/Build/Products/Debug-maccatalyst/Bighelp.app
[[ -d $built ]] || { print -u2 "No build at $built; run without --no-build."; exit 1; }

quit_copy
rm -rf "$app"
ditto "$built" "$app"
plist=$app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$plist" 2>/dev/null || true
rm -rf "$app/Contents/PlugIns" "$app/Contents/Resources/Metadata.appintents"

entitlements=$work/sandbox.entitlements
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
</dict>
</plist>
PLIST
# Nested code first (frameworks, the Debug build's dylibs), then the app with its entitlements.
find "$app/Contents" \( -name '*.dylib' -o -name '*.framework' \) -prune -print0 |
  xargs -0 -n 1 codesign --force --sign - --timestamp=none
codesign --force --sign - --timestamp=none --entitlements "$entitlements" "$app"

: > "$log"
open -n -F "$app" --stdout "$log" --stderr "$log" --args -use-demo-fixtures -disable-demo-delays "${extra[@]}"
for _ in {1..100}; do
  pid=$(running_pids | head -1)
  [[ -n $pid ]] && break
  sleep 0.1
done
[[ -n ${pid:-} ]] || { print -u2 "Bighelp didn't start; see $log"; exit 1; }
print "Running $bundle_id from $app (log: $log)"
print "$pid"
