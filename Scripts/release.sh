#!/bin/zsh
# Publishes the current version as a GitHub release that installed copies update to:
# builds the disk image, signs it into appcast.xml, tags v<version>, pushes, and uploads both.
# Needs Docs/Releases/<version>.md (what's new; shown in the update window and on GitHub).
set -euo pipefail
cd "$(dirname "$0")/.."
repo=JayanshJ/university-portal

[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first."; exit 1; }
./Scripts/package.sh
plist=".build/DerivedData/Build/Products/Release/University Portal.app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
notes="Docs/Releases/$version.md"
[[ -f $notes ]] || { echo "Write $notes first."; exit 1; }
dmg="dist/University-Portal-$version.dmg"

./Scripts/appcast.sh "$dmg" "https://github.com/$repo/releases/download/v$version/University-Portal-$version.dmg" "$notes" > dist/appcast.xml

body=$(mktemp)
trap 'rm -f "$body"' EXIT
{
  cat "$notes"
  cat <<MD

## Install
Already on 1.2 or later? The app updates itself (University Portal → Check for Updates…).

Otherwise: download **University-Portal-$version.dmg** below, open it and drag the app to Applications (replacing an older copy keeps your data and logins). The app isn't notarized, so the first time macOS blocks it: open it once, then **System Settings → Privacy & Security → Open Anyway**. "Read Me First" in the disk image explains how to connect Moodle, CMS and ChatGPT.

Requires macOS 15 or newer, Apple silicon or Intel.

SHA-256: \`$(shasum -a 256 "$dmg" | cut -d' ' -f1)\`
MD
} > "$body"

git tag "v$version"
git push origin HEAD "v$version"
gh release create "v$version" "$dmg" dist/appcast.xml --repo "$repo" --title "University Portal $version" --notes-file "$body" --latest
