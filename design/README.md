# App icon

`app_icon.svg` is the source. The PNGs in
`macos/Runner/Assets.xcassets/AppIcon.appiconset/` are generated from it.

## Regenerating

macOS has no SVG rasterizer on the command line by default, but Quick Look
will render one:

```bash
qlmanage -t -s 1024 -o . design/app_icon.svg
for s in 16 32 64 128 256 512 1024; do
  sips -s format png -z $s $s app_icon.svg.png \
    --out "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${s}.png"
done
```

`Contents.json` maps those seven files across ten slots (several sizes are
reused at 1x and 2x), so the filenames matter and shouldn't change.

## The design

A projector beam striking a caption. The diagonal is the point — a beam has
direction, so it reads as light *travelling* onto the subtitle rather than
as a glow. Lumen is named for light; the captions are what it lands on.

The first attempt centred a dot above two bars and read as a webcam or a
record button, which is the wrong signal for a player. Anything centred and
circular tends to.

16px is the binding constraint. Everything is three large shapes with wide
gaps, so when the beam falls away at small sizes the mark still reads as two
bright bars on dark — recognisably a subtitle. Check `app_icon_16.png`
before accepting any change.
