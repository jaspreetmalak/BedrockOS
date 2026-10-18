# Axis Sans

Axis Sans is Bedrock's original proportional humanist sans typeface. Its glyphs
were drawn for this project from new centerlines and round stroke outlines.
The native base cell is 14×20 pixels. No Apple, Segoe, or other external font files, outlines,
bitmaps or font-rendering libraries contributed to these assets. The legacy 5×7
bootstrap glyphs remain an independent compatibility API; Axis Sans is not a
filtered or enlarged version of that alphabet.

The design uses open apertures, round joins, a double-storey `a`, a single-storey
`g`, clear punctuation and a slashed zero. Capitals rise 12 pixels above a
15-pixel baseline; lowercase has a 9-pixel x-height. Logical advances range
from 4 to 14 pixels, rounded from the original advances multiplied by 7/6.
A UI line is 20 pixels high at scale1.

[generate_axis_sans.py](tools/generate_axis_sans.py) is the readable, original
design source. This standard-library Python tool flattens the original curve
centerlines, integrates horizontal coverage spans and averages eight vertical
subpixel samples per output row to generate the dense gray8 base atlas. It
also exports the flattened centerlines as compact fixed-point vector segments
and glyph offsets, with coordinates in units of 1/64 of a base pixel.

At integer scales 2 through 16, native painting evaluates round-stroke coverage
directly from those vectors. Pixel bounding-box and fully covered fast paths
avoid unnecessary sampling; partial edges use 8×8 subpixel coverage and 64-bit
integer distance tests. Larger text never magnifies the small base bitmap.
Painting uses no allocations, font service or external runtime dependency.
Coverage blends over the existing background through the actual RGB/BGR/scattered pixel
masks. Antialiasing preserves partial-pixel edges at every supported size, but
the display's pixel density still limits how much detail very small text can
show. A larger framebuffer alone does not automatically increase UI scale.

The original drawings and generated assets are project-authored Bedrock work,
not third-party font redistribution. No separate external font license is
required or supplied. [axis-sans.json](axis-sans.json) describes the same native
coverage and advances for independent host inspection. Regenerate both native and
host assets and the [specimen](axis-sans-specimen.png) with:

```text
python -B frameworks/public/AxisUI/tools/generate_axis_sans.py
```

`font.measure(bytes, scale)` and `font.glyphAdvance(byte)` use exactly the
advances used by `font.paint(surface, bytes, x, y, color, scale)` and
`font.paintGlyph(surface, byte, x, y, color, scale)`. Origins are signed and
clipped to the borrowed surface. CR is ignored, tabs advance four spaces, and
unsupported bytes use `?`. Text accepts scales1 through16. `font.advance` is
only an approximate column estimate; proportional fields should measure their
prefixes. Notes uses centered glyphs in fixed14-pixel editor cells.

Command-backed surfaces can supply `CommandSink.blendPixel` to composite
coverage at the receiver without granting framebuffer reads. Primary menus
forward that operation to their parent pixel surface. Historical command sinks
without the optional callback retain a threshold fallback.

Historical diagnostic hosts can explicitly set `surface.legacy_text = true` to
select the original5×7 face for declarative text. Both layout and painting then
use the matching6-pixel advance and10-pixel line metrics. The flag defaults to
false on every surface and is never inferred from the command transport; native
GUI text and new command overlays retain Axis Sans. Direct `font.paint` always
draws Axis Sans.
