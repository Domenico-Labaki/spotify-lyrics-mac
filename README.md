# Spotify Lyrics for macOS

A small native menu bar app that displays the current lyric line while Spotify plays. It works with the Spotify desktop app and Spotify Free; it does not require a Spotify developer account or Premium subscription.

## Features

- Displays provider-timed lyrics in a fixed-width menu bar item.
- Animates transitions between lines and scrolls long lines during their available time. macOS Reduce Motion disables these animations.
- Tints the lyric background with a subtle, translucent gradient based on the album cover.
- Collapses to a music note when no timed lyrics are available.
- Caches successful lyrics and artwork locally for 30 days, up to 200 entries per cache; temporary lookup failures are retried while the track is playing.
- Requests registration as a login item when launched.

## Requirements

- An Apple Silicon Mac with macOS 26 or later for the supplied release build.
- The Spotify desktop app, running and playing music. Spotify Free works; browser playback and other devices are not supported.
- An internet connection to fetch uncached lyrics and artwork.

## Install

1. Download `Spotify-Lyrics-mac-v0.1.0.zip` from the [latest release](https://github.com/Domenico-Labaki/spotify-lyrics-mac/releases/latest) and unzip it.
2. Move **Spotify Lyrics.app** to a permanent location such as Applications before launching it, particularly if you want it to start at login.
3. Open the app and allow it to control Spotify when macOS asks. The app reads playback information; it does not change playback.
4. Play a song in Spotify. Look for its lyric line or ♪ in the menu bar. Click the item for the Quit command.

The release is an **ad-hoc signed, non-notarized development build**, not an Apple-notarized app. macOS may block or warn about it. If you trust this release, use the options macOS provides in Privacy & Security to open it. Gatekeeper behavior depends on macOS settings. The app requests launch-at-login registration on launch; check **System Settings → General → Login Items** to confirm or change it.

## How it works

Spotify's AppleScript interface supplies the track metadata, playback state, position and album artwork URL. The app searches [LRCLIB](https://lrclib.net/) for existing timestamped lyrics and compares those timestamps with playback position. It does not generate or align timestamps, capture audio, or use the Spotify Web API. Only timed results are displayed.

The lyric item can be moved using the macOS menu bar rearrangement gesture: hold **Command** and drag the item. macOS controls available menu bar space, so items may be hidden if the bar is crowded.

## Privacy and local data

The app sends the current track title, artist and album to LRCLIB for lookup, and downloads album artwork from Spotify's image host. It reads playback metadata locally through macOS Automation. It does not require a Spotify login within the app or collect analytics.

Cached lyric text and artwork are stored in `~/Library/Caches/SpotifyLyrics/`. The app does not cache failed lookups. You can quit the app and delete this folder to clear the cache; macOS may also clear cache files. Lyrics and artwork availability and timing depend on their providers.

## Troubleshooting

- **Only ♪ appears:** Spotify may be paused, the current line may be empty, timed lyrics may not be available, or the lyrics service may be temporarily unavailable. Hover over the item for its status. Temporary service errors are retried every five seconds while the same track plays.
- **No permission prompt or no playback data:** Check **System Settings → Privacy & Security → Automation** and allow Spotify Lyrics to access Spotify.
- **Wrong or mistimed lyrics:** LRCLIB may have a different recording or inaccurate timestamps. The app uses provider timing without generating its own alignment.
- **App doesn't start at login:** Check **System Settings → General → Login Items**, and keep the app in a permanent location. Login-item registration can be affected by macOS settings.
- **The menu bar item is missing:** The menu bar may be full; free up space or rearrange its items.

## Build and test

Install Apple Command Line Tools and run:

```sh
./scripts/build.sh
./scripts/test.sh
```

The build script compiles for the architecture and macOS SDK of the build machine, signs the app ad hoc, and writes `build/Spotify Lyrics.app`. The release archive is built separately with `ditto`. No third-party build dependencies are required.

## Limitations

This is an early personal utility. Track matching and lyric coverage depend on LRCLIB, and some tracks or ads have no timed lyrics. The supplied build has not been notarized or tested on Intel Macs. Spotify and LRCLIB are independent services and may change their interfaces or availability.

Spotify is a trademark of Spotify AB. This project is not affiliated with Spotify or LRCLIB.
