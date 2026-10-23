#!/bin/zsh
# Builds the universal Release app into .build/DerivedData and signs Sparkle's helpers with the
# app's certificate (Xcode re-signs only the framework itself; the helpers ship ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

identity="Conscious Dev"
xcodebuild -project UniversityPortal.xcodeproj -scheme UniversityPortal -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath .build/DerivedData "$@" build | grep -E "error:|BUILD"

app=".build/DerivedData/Build/Products/Release/University Portal.app"
fw="$app/Contents/Frameworks/Sparkle.framework"
# Inside out, without --deep (Sparkle's sandboxing guide).
codesign -f -s "$identity" -o runtime "$fw/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$identity" -o runtime --preserve-metadata=entitlements "$fw/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$identity" -o runtime "$fw/Versions/B/Autoupdate"
codesign -f -s "$identity" -o runtime "$fw/Versions/B/Updater.app"
codesign -f -s "$identity" -o runtime "$fw"
codesign -f -s "$identity" -o runtime --preserve-metadata=entitlements,requirements,flags "$app"
codesign --verify --deep --strict "$app"
