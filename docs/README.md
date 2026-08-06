# Landing page

`index.html` is self-contained — no build step, no dependencies, no external
requests. Open it directly or drop it on any static host.

Served by GitHub Pages from this folder, which is why it is named `docs/`:
Pages only offers the repository root or `/docs` as a source, so the name is
load-bearing rather than descriptive. `.nojekyll` stops Pages running the
file through Jekyll.

## When cutting a release

The download buttons point at:

```
https://github.com/ritesh59697/lumen/releases/latest/download/Lumen-arm64.dmg
```

Both halves of that URL are deliberately version-free — `latest` resolves to
the newest release, and the asset name never changes — so the links do not
need touching when a version ships. **Attach the `.dmg` under exactly that
filename**, or the links break silently.

Nothing else on this page needs updating for a release. The version number
and file size used to be printed on the download buttons and went stale
every single time, because editing them meant a commit and a Pages redeploy
that lagged the release by minutes. Both are now omitted, and the page links
to the releases list instead — which is accurate by construction.

Resist adding them back.

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
