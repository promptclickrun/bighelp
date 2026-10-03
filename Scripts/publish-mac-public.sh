#!/bin/zsh
# Posts a Mac build from Scripts/release-mac.sh on the public repo, promptclickrun/bighelp, as
# mac-v<version>-<build> marked Latest, with the DMG, its .sha256 and appcast.xml. Installed
# copies read releases/latest/download/appcast.xml (Info.plist SUFeedURL), so this is what
# offers them the update. Run it after this build's PR is merged to main: the tag points at
# that main.
# Usage: Scripts/publish-mac-public.sh [--dry-run]
# Reads release-mac.sh's output (BIGHELP_MAC_RELEASE_DIR, /tmp/bighelp-mac-release) and its
# DerivedData (Sparkle's tools). Needs the Sparkle key in the login Keychain and gh signed in.
set -euo pipefail
out=${BIGHELP_MAC_RELEASE_DIR:-/tmp/bighelp-mac-release}
derived=${BIGHELP_MAC_RELEASE_DERIVED:-/tmp/bighelp-mac-release-dd}
public=promptclickrun/bighelp
dry=0
while (( $# )); do
  case $1 in
    --dry-run) dry=1 ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
  shift
done
fail() { print -u2 "$1"; exit 1; }

dmgs=("$out"/bighelp-*-mac.dmg(N))
(( ${#dmgs} == 1 )) || fail "Expected one bighelp-<version>-<build>-mac.dmg in $out; run Scripts/release-mac.sh."
dmg=${dmgs[1]} name=${dmgs[1]:t}
[[ $name =~ '^bighelp-([0-9]+(\.[0-9]+)+)-([0-9]+)-mac\.dmg$' ]] || fail "Unexpected disk image name: $name"
version=$match[1] build=$match[3]
tag=mac-v$version-$build
url=https://github.com/$public/releases/download/$tag/$name
for file in "$dmg.sha256" "$out/appcast.xml" "$out/notes.md"; do
  [[ -s $file ]] || fail "Missing $file; run Scripts/release-mac.sh."
done

# The three files agree, the update is signed with bighelp's key, and Apple notarized it
# (update test builds skip notarization, so they can never get here).
(cd "$out" && shasum -a 256 -c "$name.sha256" >/dev/null) || fail "$name doesn't match its .sha256."
signature=$(python3 - "$out/appcast.xml" "$url" "$(stat -f %z "$dmg")" "$version" "$build" <<'PY'
import sys
from xml.etree import ElementTree
path, url, length, version, build = sys.argv[1:]
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ElementTree.parse(path).findall("channel/item")
if len(items) != 1:
    sys.exit("appcast.xml should hold exactly one release.")
item = items[0]
enclosure = item.find("enclosure")
found = (item.findtext(sparkle + "version"), item.findtext(sparkle + "shortVersionString"),
         enclosure.get("url"), enclosure.get("length"))
if found != (build, version, url, length):
    sys.exit(f"appcast.xml says {found}, expected {(build, version, url, length)}.")
print(enclosure.get(sparkle + "edSignature"))
PY
) || fail "appcast.xml doesn't describe $name at $url."
sparkle=$derived/SourcePackages/artifacts/sparkle/Sparkle/bin
[[ -x $sparkle/sign_update ]] || fail "Sparkle's sign_update isn't in $sparkle."
ed_key() { security find-generic-password -s bighelp-sparkle-ed25519 -a bighelp -w; }
ed_key | "$sparkle/sign_update" --ed-key-file - --verify "$out/appcast.xml" >/dev/null || fail "appcast.xml isn't signed."
ed_key | "$sparkle/sign_update" --ed-key-file - --verify "$dmg" "$signature" >/dev/null || fail "$name's signature is wrong."
xcrun stapler validate -q "$dmg" || fail "$name isn't notarized and stapled."

# The public main must already carry this build, and the tag must be new.
public_build=$(gh api "repos/$public/contents/project.yml" --jq .content | base64 -d |
  awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }')
[[ $public_build == "$build" ]] || fail "The public main is at build $public_build, not $build: merge this build's PR first."
! gh release view "$tag" -R "$public" >/dev/null 2>&1 || fail "$tag already exists on $public."

{ cat "$out/notes.md"; print "\n\nSHA-256: \`$(awk '{ print $1 }' "$dmg.sha256")\`"; } > "$out/public-notes.md"
release=(gh release create "$tag" -R "$public" --target main --latest --title "bighelp for Mac $version ($build)"
  --notes-file "$out/public-notes.md" "$dmg" "$dmg.sha256" "$out/appcast.xml")
if (( dry )); then
  print "Ready. Would run:"; print -r -- "${(q-)release[@]}"
  exit 0
fi
"${release[@]}"

# What installed copies will now read.
curl -fsSL --retry 3 "https://github.com/$public/releases/latest/download/appcast.xml" | cmp -s - "$out/appcast.xml" ||
  fail "The public feed doesn't serve this appcast.xml yet; check that $tag is marked Latest."
print "Installed copies are now offered bighelp for Mac $version ($build)."
