#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
swiftc -module-cache-path build/module-cache Sources/LyricsText.swift Tests/main.swift -o build/lyrics-text-tests
swiftc -module-cache-path build/module-cache Sources/ArtworkColors.swift Tests/Artwork/main.swift -o build/artwork-tests
swiftc -module-cache-path build/module-cache Sources/TrackCache.swift Tests/Cache/main.swift -o build/cache-tests
build/lyrics-text-tests
build/artwork-tests
build/cache-tests
