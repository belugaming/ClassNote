# MarkdownView, patched

[LiYanan2004/MarkdownView](https://github.com/LiYanan2004/MarkdownView) **3.0.0**
(MIT, see `LICENSE`), with one change: how a formula is drawn. Everything
else in `Sources/` is the release as published; the upstream DocC catalog and
tests are left out.

## Formulas are typeset once and drawn as images

Upstream, every formula, inline or display, was a `ViewThatFits` holding two
live `MTMathUILabel`s (AppKit views), one of them inside a horizontal scroll
view. Each label parsed its LaTeX again on every view update and ran SwiftMath's
whole typesetter on every size query, with no cache. A paragraph of notes with
a few formulas therefore created a dozen AppKit views and typeset each formula
several times whenever it scrolled into view, which is enough to miss frames at
120 Hz, and more on slower Macs.

Now `SwiftMathImageCache` parses and typesets a formula once per look (LaTeX,
size, inline or display, light or dark) with SwiftMath's own `MTMathImage`, and
the view draws that image. The image draws the typeset glyphs on demand, so it
is sharp on any screen. A formula wider than the space it has is scaled down to
fit instead of scrolling sideways, and LaTeX the typesetter cannot read is shown
as its source instead of nothing.

Files changed:

- `Sources/MarkdownView/Rendering/Shared/Math/SwiftMathView.swift`
- `Sources/MarkdownView/Rendering/Shared/Math/InlineMath.swift`
- `Sources/MarkdownView/Rendering/Shared/Math/MarkdownDisplayMathView.swift`

## Updating

Copy `Sources/MarkdownView` and `Package.swift` from the new release (leaving
out `Documentation.docc` and the test target), then apply the change above to
the three files again, and update the version at the top of this file.
