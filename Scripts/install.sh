#!/bin/zsh
# Builds a Release copy and installs it as /Applications/University Portal.app.
# Data and Keychain approvals carry over (same bundle ID and signing certificate).
set -euo pipefail
cd "$(dirname "$0")/.."

osascript -e 'quit app "University Portal"' 2>/dev/null || true
./Scripts/build.sh

# Replace, not merge: files dropped from the app must not linger and break its signature.
rm -rf "/Applications/University Portal.app"
ditto ".build/DerivedData/Build/Products/Release/University Portal.app" "/Applications/University Portal.app"

# Only the installed copy should receive moodlemobile:// links.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in .build/DerivedData/Build/Products/*/*.app(N); do "$lsregister" -u "$PWD/$app" 2>/dev/null || true; done
"$lsregister" -f "/Applications/University Portal.app"

open "/Applications/University Portal.app"
echo "Installed /Applications/University Portal.app"
