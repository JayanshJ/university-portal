#!/bin/zsh
# Builds a Release copy and packages it as dist/University-Portal-<version>.dmg for sharing:
# the app, a shortcut to Applications to drag it onto, and "Read Me First.txt".
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build.sh

app=".build/DerivedData/Build/Products/Release/University Portal.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="dist/University-Portal-$version.dmg"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/University Portal.app"
ln -s /Applications "$staging/Applications"
cp "Config/Distribution/Read Me First.txt" "$staging/"

mkdir -p dist
rm -f "$dmg"
hdiutil create -volname "University Portal" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
codesign --sign "Conscious Dev" "$dmg"
echo "Created $dmg ($(du -h "$dmg" | cut -f1))"
