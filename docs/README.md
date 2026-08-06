# Landing page

`index.html` is self-contained — no build step, no dependencies, no external
requests. Open it directly or drop it on any static host.

Served by GitHub Pages from this folder, which is why it is named `docs/`:
Pages only offers the repository root or `/docs` as a source, so the name is
load-bearing rather than descriptive. `.nojekyll` stops Pages running the
file through Jekyll.

## When cutting a release

The download buttons point at `releases/latest/download/`, which resolves to
the newest release automatically — but the filename is versioned, so it does
need updating when the version changes:

```
Lumen-1.0.0-arm64.dmg
```

The version string in the hero button and the size on the footer button are
both hardcoded, and should be updated alongside `pubspec.yaml`.

## Design notes

The page commits to a single dark theme rather than offering both. Lumen is a
video player — a light-mode marketing page would misrepresent what the app
actually looks like.

The hero animation replays real transcription output, timed against a real
timecode, so the page demonstrates the product instead of describing it. It
honours `prefers-reduced-motion` by showing the finished cue instead.

The first-run Gatekeeper note is deliberately placed next to the download
rather than buried further down. Users who meet that dialog without warning
tend to assume the app is broken.
