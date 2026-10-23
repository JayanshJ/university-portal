#!/bin/zsh
# Prints a one-item Sparkle appcast for a disk image built by package.sh.
#   Scripts/appcast.sh <dmg> <download-url> <release-notes.md>
# Signs the image with the EdDSA key in the Keychain (account "university-portal",
# created with Sparkle's generate_keys); the app checks it against SUPublicEDKey.
set -euo pipefail
cd "$(dirname "$0")/.."
dmg=$1 url=$2 notes=$3

sparkle=.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
app=".build/DerivedData/Build/Products/Release/University Portal.app"
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
minimum=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist")
signature=$("$sparkle/sign_update" --account university-portal "$dmg")  # sparkle:edSignature="…" length="…"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>University Portal</title>
    <item>
      <title>Version $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
$(cat "$notes")
]]></description>
      <enclosure url="$url" $signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
