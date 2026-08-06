# Lumen

A free, offline media player that generates subtitles for any video — no cloud, no account,
nothing leaves your machine.

Plays what VLC plays. Transcribes like Buzz does. In one app.

## Why

Plenty of players handle any format. Plenty of tools transcribe audio. Doing both in one place,
entirely on-device, is the gap Lumen fills — you open a video with no subtitles, click one
button, and watch it with captions a few seconds later.

Everything runs locally. There is no API key, no upload, and no telemetry.

## Features

**Playback**
- Practically any container and codec (mp4, mkv, avi, webm, mov, ts, …) via libmpv
- Hardware-accelerated decoding
- External subtitle files (SRT, VTT, ASS, SSA), auto-loaded from alongside the video
- Playlists with shuffle, repeat, drag-to-reorder, and natural sort (`ep2` before `ep10`)
- Keyboard shortcuts following VLC/mpv conventions

**Offline captions**
- One-click generation using [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
- Model sizes from tiny to large-v3-turbo, trading speed against accuracy
- Metal GPU acceleration on Apple silicon
- 99 languages, with optional translation to English
- Voice activity detection, so silence is skipped rather than transcribed

**Subtitle editing**
- Fix text inline while the video plays; the cue under the playhead is highlighted
- Per-cue timing nudges, plus retime-to-playhead and split-at-playhead
- Merge cues that Whisper split mid-sentence
- Shift every cue at once when subtitles drift out of sync
- Undo/redo, and export anywhere

## Requirements

- **macOS** 10.15 or later, **Apple silicon only** (M1 and newer)
- Roughly 100 MB of disk for the app, plus whatever models you download
  (base is ~142 MB, and is the recommended starting point)

Intel Macs are not supported. `whisper_ggml_plus` excludes ggml's x86 sources
in its podspec, so the x86_64 half of a universal binary cannot link. This is
upstream, not a choice made here.

Android support is planned; the codebase is cross-platform Flutter, and the Android
toolchain simply has not been wired up yet.

## Building from source

```bash
flutter pub get
flutter build macos --release
```

The built app lands in `build/macos/Build/Products/Release/`.

Requires Flutter 3.44+, Xcode, and CocoaPods. None of the native plugins support Swift Package
Manager, so disable it to avoid a spurious keychain prompt during the build:

```bash
flutter config --no-enable-swift-package-manager
```

## Tests

```bash
flutter test
```

The suite covers the subtitle pipeline end to end — parsing malformed real-world SRT files,
sanitizing raw Whisper output, timing arithmetic, undo semantics, and playlist bookkeeping.
It includes a fixture captured from genuine whisper.cpp output rather than an idealized one.

## How it works

```
video ──► FFmpeg ──► 16 kHz mono WAV ──► whisper.cpp ──► segments
                                                            │
                                          sanitizer ◄───────┘
                                              │
                                    .srt ─────┴───► player
```

Playback and transcription are deliberately kept apart. They share only a file path, so a
transcription can fail, be cancelled, or be restarted without ever disturbing playback.

Whisper accepts exactly one input format — 16 kHz mono 16-bit PCM — and silently produces
garbage for anything else, so those parameters are fixed rather than configurable.

Raw Whisper output is not usable as subtitles as-is: segments arrive padded with spaces,
carrying `[BLANK_AUDIO]` markers, occasionally zero-length or overlapping, and often far too
long to read. The sanitizer between the engine and the player is what turns that into
something watchable.

## Built with

- [Flutter](https://flutter.dev) — cross-platform UI
- [media_kit](https://github.com/media-kit/media-kit) — libmpv-backed playback
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) via
  [whisper_ggml_plus](https://pub.dev/packages/whisper_ggml_plus) — on-device speech recognition
- [FFmpegKit](https://pub.dev/packages/ffmpeg_kit_flutter_new_audio) — audio extraction
  (LGPL audio build)

## License

MIT — see [LICENSE](LICENSE).

The bundled native components carry their own licenses: libmpv and FFmpeg are LGPL, and
whisper.cpp is MIT. The FFmpeg build used here is deliberately the LGPL audio variant rather
than a GPL one, to keep this project's licensing options open.
