# Quaydeck brand

A quay is the harbour wall where ships berth and are counted. A deck is the overview.
Quaydeck is where your dev servers are moored, and you see them all at once.

Write it as one word with a capital Q: **Quaydeck**.

## The mark

A porthole: a brass ring with calm water inside. You look through it and see what is
docked. The app icon is `icon/AppIcon-1024.png`; everything else is generated from it.

- Keep the plate, the ring and the water together. Do not recolour, outline, rotate or
  add text to it.
- It holds up down to 16 px (`icon/png/`). Below that, use the menu bar glyph.
- In the menu bar the app shows the SF Symbol `circle.bottomhalf.filled` (the same
  porthole) when nothing runs, and a numbered circle when servers are running.

`icon/concepts/` keeps the two directions that were not chosen, a row of berths and a
mooring cleat, for illustration only.

## Colour

| Token | Hex | Use |
| --- | --- | --- |
| harbour-deep | `#0B1D32` | Backgrounds, the icon plate |
| harbour | `#14374F` | Raised surfaces, gradients from deep |
| brass | `#F1C47B` | The one accent: the ring, links, highlights |
| brass-dim | `#C79A55` | Brass on light backgrounds, pressed states |
| water | `#47A7A6` | Secondary accent, the water line |
| ink | `#EAF1F7` | Text on harbour backgrounds |
| muted | `#8EA5B8` | Secondary text on harbour backgrounds |
| status-ok / warn / alert | `#5FC98A` `#E9A44E` `#E8705F` | Server health only, never decoration |

Tokens live in `colors.json` and `colors.css`. Brass is an accent: one brass thing
per view reads as a light on the water; five read as a sale.

Inside the app, section icons use Claude's coral and Docker's blue. Those colours point
at those products. Never use their logos.

## Type

SF Pro, the system font, for everything. Quaydeck is a native Mac utility and should
look like one. SF Mono appears only where the content is genuinely tabular: port
numbers. Large headlines tighten (about -1.5 pt tracking at 76 pt); body text stays at
the default.

## Words

Short and concrete. Say what it does, in the reader's terms:
"Every dev server on your Mac, in your menu bar." No hype, no exclamation marks, no
"supercharge". Name things the way the menu does: servers, ports, containers, sessions.

## Imagery

A harbour at night: still water, a few brass lights, deep navy. Calm, never busy.
`art/harbour-backdrop.jpg` is a desktop backdrop for screenshots; `art/harbour-quay.jpg`
leaves its left half empty for a headline.

Generated images never contain text, numbers or logos. Words are set in code on top.

## Screenshots

`screenshots/` and `social/` are rendered from the real menu, fed by a fictional Mac
(`Tools/Screenshots/Sources/Screenshots/DemoMachine.swift`). Nothing in them comes from
a real machine, and nothing should: no real project names, paths or chats. Regenerate
after a UI change:

```sh
swift run --package-path Tools/Screenshots Screenshots "$PWD"
sips -z 630 1200 brand/social/og-image@2x.jpg --out brand/social/og-image.jpg
```

## Files

| Path | What |
| --- | --- |
| `icon/AppIcon-1024.png` | Master icon. `Scripts/make-icon.sh` builds `Resources/AppIcon.icns` from it |
| `icon/png/` | 16 to 512 px exports |
| `screenshots/desktop.jpg` | 2880x1800, the menu open on a night harbour desktop |
| `screenshots/menu-light.png`, `menu-dark.png` | The menu alone, transparent background |
| `social/og-image.jpg` | 1200x630 link preview (`@2x` alongside) |
| `art/` | Backdrops without text |
| `colors.json`, `colors.css` | Palette tokens |
