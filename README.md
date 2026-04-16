# Eno Music iOS

This is a native iOS version of Eno Music. It does not require Node to open or build in Xcode.

## Open

Open `EnoMusicIOS.xcodeproj` in Xcode.

If command-line builds still point to Command Line Tools, use the full Xcode developer directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project EnoMusicIOS.xcodeproj -scheme EnoMusicIOS -destination 'generic/platform=iOS' -derivedDataPath ./Build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

## Current Features

- SwiftUI app entry.
- `WKWebView` loading bundled `EnoMusicIOS/Web/index.html`.
- JavaScript-to-Swift bridge through `window.enoPlatform.invoke(...)`.
- Bilibili search and audio playback through native bridge channels.
- Bilibili login through bundled web login and QR login flows.
- Cookie storage in Keychain.
- Native `AVPlayer` playback with background audio, lock screen controls, next/previous commands, progress updates, and seek.
- Search queue, recently played items, and favorites persisted locally.
- Mobile app UI with search, favorites, history, mini player, full player, settings page, toast feedback, and loading states.

## Notes

- The app currently uses a bundled HTML interface for fast native iOS iteration without requiring Node.
- Signing is disabled in the command above. To install on a real iPhone, open the project in Xcode and set your team/signing settings.
- Simulator services may emit warnings in sandboxed command-line builds. The generic iOS build is still valid when it ends with `BUILD SUCCEEDED`.
