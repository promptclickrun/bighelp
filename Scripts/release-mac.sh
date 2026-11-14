#!/bin/zsh
# The Mac app (the iPad app through Mac Catalyst) as a signed, notarized DMG on this
# repo's GitHub Releases. It never goes to App Store Connect: the archive is exported
# with Developer ID. It shares the iPhone app's ID for pushes, so never upload it.
# Next to the DMG it writes its .sha256 and the signed Sparkle appcast.xml that installed
# copies read for updates; Scripts/publish-mac-public.sh posts all three publicly.
# Usage: Scripts/release-mac.sh [--notes-file notes.md] [--draft] [--no-publish]
# Update tests only (never published): --build-number <n> --no-notarize --feed-base-url <url>
#   build a numbered copy, skip Apple's notarization, and point its appcast at a local server.
# Needs Config/Local.xcconfig (the team), a "Developer ID Application" certificate in the
# keychain, the Sparkle signing key (login Keychain item bighelp-sparkle-ed25519), the asc
# CLI signed in (it notarizes) and gh signed in (it publishes).
set -euo pipefail
repo=${0:A:h:h}
out=${BIGHELP_MAC_RELEASE_DIR:-/tmp/bighelp-mac-release}
derived=${BIGHELP_MAC_RELEASE_DERIVED:-/tmp/bighelp-mac-release-dd}
publish=1 notarize=1 draft=() notes_file= build= feed_base=
while (( $# )); do
  case $1 in
    --no-publish) publish=0 ;;
    --draft) draft=(--draft) ;;
    --notes-file) notes_file=${2:A}; shift ;;
    --build-number) build=$2; shift ;;
    --no-notarize) notarize=0 ;;
    --feed-base-url) feed_base=${2%/}; shift ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
  shift
done
if (( publish )) && [[ -n $build || -n $feed_base ]] || (( publish && ! notarize )); then
  print -u2 "--build-number, --no-notarize and --feed-base-url are for update tests: add --no-publish."
  exit 2
fi
[[ -z $build || $build == <1-> ]] || { print -u2 "--build-number takes a whole number."; exit 2; }

version=$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$repo/project.yml")
build=${build:-$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$repo/project.yml")}
team=$(awk -F' *= *' '/^DEVELOPMENT_TEAM/ { print $2 }' "$repo/Config/Local.xcconfig")
identity=$(security find-identity -v -p codesigning | awk -v team="($team)" '/Developer ID Application/ && index($0, team) { print $2; exit }')
[[ -n $team && -n $identity ]] || { print -u2 "Needs DEVELOPMENT_TEAM in Config/Local.xcconfig and its Developer ID Application certificate."; exit 1; }
# Sparkle's EdDSA key. Lose it and installed copies can't update any more: keep a backup.
ed_key() { security find-generic-password -s bighelp-sparkle-ed25519 -a bighelp -w; }
ed_key >/dev/null || { print -u2 "Needs the Sparkle signing key: login Keychain item bighelp-sparkle-ed25519."; exit 1; }
dmg=$out/bighelp-$version-$build-mac.dmg
tag=mac-v$version-$build
public=https://github.com/promptclickrun/bighelp/releases

rm -rf "$out"
mkdir -p "$out/dmg"
xcodebuild archive -project "$repo/Bighelp.xcodeproj" -scheme BighelpCatalyst -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath "$out/bighelp.xcarchive" \
  -derivedDataPath "$derived" -allowProvisioningUpdates -quiet CURRENT_PROJECT_VERSION="$build"
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/bighelp.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates -quiet
app=$out/export/Bighelp.app
codesign --verify --deep --strict "$app"
info() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist"; }
[[ $(info CFBundleVersion) == "$build" ]] || { print -u2 "The app's build isn't $build."; exit 1; }

# Drag-to-Applications disk image, signed itself so Gatekeeper checks the download too.
# Stapling fails unless Apple accepted the notarization.
ditto "$app" "$out/dmg/Bighelp.app"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -volname Bighelp -srcfolder "$out/dmg" -format UDZO -ov "$dmg" -quiet
codesign --sign "$identity" --timestamp "$dmg"
if (( notarize )); then
  asc notarization submit --file "$dmg" --wait --output table
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
(cd "$out" && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")

# Sparkle's update feed. The app only takes a signed feed and an update signed with the
# key whose public half is its SUPublicEDKey, so check that the Keychain holds that key.
sparkle=$derived/SourcePackages/artifacts/sparkle/Sparkle/bin
[[ -x $sparkle/sign_update ]] || { print -u2 "Sparkle's sign_update isn't in $sparkle."; exit 1; }
[[ $(ed_key | xcrun swift "$repo/Scripts/sparkle-public-key.swift") == "$(info SUPublicEDKey)" ]] || {
  print -u2 "The Keychain's Sparkle key doesn't match the app's SUPublicEDKey."; exit 1; }
signature=$(ed_key | "$sparkle/sign_update" --ed-key-file - -p "$dmg")
if [[ -n $notes_file ]]; then
  cp "$notes_file" "$out/notes.md"
else
  print "Bighelp for Mac $version ($build). Open the disk image and drag Bighelp to Applications." > "$out/notes.md"
fi
feed=(--download-url "${feed_base:-$public/download/$tag}/${dmg:t}")
[[ -n $feed_base ]] || feed+=(--release-url "$public/tag/$tag")
python3 "$repo/Scripts/mac_appcast.py" --version "$version" --build "$build" --dmg "$dmg" \
  --signature "$signature" "${feed[@]}" --notes "$out/notes.md" \
  --minimum-system-version "$(info LSMinimumSystemVersion)" --output "$out/appcast.xml"
ed_key | "$sparkle/sign_update" --ed-key-file - "$out/appcast.xml" >/dev/null
ed_key | "$sparkle/sign_update" --ed-key-file - --verify "$out/appcast.xml"
ed_key | "$sparkle/sign_update" --ed-key-file - --verify "$dmg" "$signature"
print "Built $dmg with ${dmg:t}.sha256 and appcast.xml"

(( publish )) || exit 0
# The release goes to this checkout's GitHub repo, tagged at the commit that was built.
cd "$repo"
gh release create "$tag" "$dmg" --target "$(git rev-parse HEAD)" \
  --title "Bighelp for Mac $version ($build)" --notes-file "$out/notes.md" "${draft[@]}"
