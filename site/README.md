# Landing page

`index.html` is self-contained — no build step, no dependencies, no external
requests. Open it directly or drop it on any static host (GitHub Pages,
Netlify, Vercel).

## Before publishing

The two download buttons point at `#` and `#download`. Once a release exists,
point both at the `.dmg`:

```
<a class="btn" href="https://github.com/ritesh59697/lumen/releases/latest/download/Lumen.dmg">
```

The version string in the hero button (`v1.0.0`) is hardcoded and needs
updating alongside `pubspec.yaml`.

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
