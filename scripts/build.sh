#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
APP="build/Spotify Lyrics.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -module-cache-path build/module-cache -swift-version 5 -O Sources/main.swift Sources/LyricsText.swift Sources/ArtworkColors.swift Sources/TrackCache.swift -o "$APP/Contents/MacOS/Spotify Lyrics" -framework AppKit
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Spotify Lyrics</string>
<key>CFBundleIdentifier</key><string>local.spotifylyrics.menubar</string>
<key>CFBundleName</key><string>Spotify Lyrics</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.2</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Spotify Lyrics reads the current track and playback position to display its timed lyrics.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
printf 'Built %s\n' "$APP"
