# Lumen — Web App Visual System Audit

> Source of truth: [`src/styles.css`](../src/styles.css). This document is the design-token contract to carry into the Flutter / iOS port. Lumen is a **warm, editorial paper-and-ink** surface — deliberately _not_ a flat dark app. Every decision below reinforces "calm journal you write into," not "SaaS dashboard."

---

## 1. Color tokens

All colors are authored in **OKLCH** (`oklch(L C H)` — lightness 0–1, chroma, hue°). OKLCH is used on purpose: it lets the palette derive variants by nudging one channel (e.g. `oklch(from var(--amber) l c h / 0.5)` for pulses) and keeps perceptual lightness stable across hues. **Flutter has no OKLCH** — these must be converted to sRGB hex/`Color(0xAARRGGBB)` at port time (see §7).

### Core named palette (`:root`, light mode)

| Token          | OKLCH                  | Role                                              | Approx sRGB |
| -------------- | ---------------------- | ------------------------------------------------- | ----------- |
| `--paper`      | `oklch(0.97 0.012 85)` | App background — warm off-white, faint amber tint | `#F7F3EA`   |
| `--ink`        | `oklch(0.18 0.015 50)` | Primary text / foreground — warm near-black       | `#2B2620`   |
| `--amber`      | `oklch(0.72 0.16 60)`  | Accent / brand / active state                     | `#D08A3E`   |
| `--amber-soft` | `oklch(0.88 0.06 70)`  | Muted amber wash                                  | `#EAD3B4`   |
| `--sage`       | `oklch(0.55 0.06 160)` | Secondary accent (calm green)                     | `#5E8A78`   |

### Semantic tokens (shadcn-style, mapped from the palette)

| Token                  | Light value            | Notes                                                          |
| ---------------------- | ---------------------- | -------------------------------------------------------------- |
| `--background`         | → `--paper`            |                                                                |
| `--foreground`         | → `--ink`              |                                                                |
| `--card` / `--popover` | `oklch(0.99 0.008 85)` | Slightly **lighter** than paper — cards float _above_ the page |
| `--primary`            | → `--ink`              | Primary buttons = ink fill, paper text (inverted)              |
| `--secondary`          | `oklch(0.92 0.015 80)` |                                                                |
| `--muted`              | `oklch(0.93 0.012 80)` |                                                                |
| `--muted-foreground`   | `oklch(0.42 0.02 60)`  | Captions, labels, metadata                                     |
| `--accent`             | → `--amber`            |                                                                |
| `--destructive`        | `oklch(0.55 0.2 25)`   | Clear/delete actions                                           |
| `--border`             | `oklch(0.85 0.018 75)` | Hairline — low contrast, warm                                  |
| `--input`              | `oklch(0.88 0.015 80)` |                                                                |
| `--ring`               | → `--amber`            | Focus ring                                                     |

### Chart / data-viz ramp

`--chart-1`=amber, `--chart-2`=sage, then `oklch(0.5 0.12 280)` (violet), `oklch(0.6 0.15 20)` (red-orange), `oklch(0.7 0.1 200)` (cyan).

### Dark mode (`.dark`)

A full parallel set. Key inversions: `--paper` → `oklch(0.16 0.012 60)` (warm near-black, **not** pure `#000`), `--ink` → `oklch(0.94 0.012 80)`. Cards stay _lighter_ than the dark paper (`0.21`) — same "float above" relationship, preserved. `--amber-soft` flips to a dark muted amber (`0.35`). The dark theme is still warm-hued (hue ~60), never neutral gray.

### ⚠️ Finding — entity colors live outside the token system

The knowledge-graph node palette is **hardcoded hex** in [`src/components/graph-view.tsx:48`](../src/components/graph-view.tsx), independent of the OKLCH tokens — because it paints to `<canvas>`, which can't read CSS custom properties cheaply:

```
person #c97b3a   place #5b8a72   organization #7a6dc4   project #c0a040
event  #cf6a52   activity #4aa39e  concept #4a7ab8   emotion #b85a8a   other #8a8a8a
```

Plus hardcoded fallbacks `cardBg = #fbf7ec` and stroke/label ink `#1a1208`. **For the Flutter port these are a second, real palette** — they must be ported as explicit values and ideally reconciled into one shared token table so the graph and the chrome don't drift.

---

## 2. Typography

| Family token     | Stack                                           | Use                                                     |
| ---------------- | ----------------------------------------------- | ------------------------------------------------------- |
| `--font-display` | **Fraunces**, "Iowan Old Style", Georgia, serif | Headings `h1–h3`, `.font-display`. The editorial voice. |
| `--font-sans`    | **Inter**, ui-sans-serif, system-ui             | Body, UI, default on `<body>`                           |
| `--font-mono`    | **JetBrains Mono**, ui-monospace                | Rare — code/IDs only                                    |

**Display treatment** (`@layer base`): Fraunces ships with `font-feature-settings: "ss01","ss02"` (stylistic sets) and `letter-spacing: 0`. iOS equivalent: bundle Fraunces variable font and enable the matching OpenType features; fall back to a serif (Iowan Old Style is iOS-native).

**Observed micro-conventions** (carry these — they define the feel as much as the families):

- Labels/eyebrows: tiny, uppercase, **wide tracking** — `text-[10px]`/`text-[11px]`, `uppercase`, `tracking-[0.14em]`–`tracking-[0.22em]`, `font-medium`, `text-muted-foreground`.
- Body sits at `text-xs`/`text-sm`; the app is information-dense but quiet.
- Inter does the work; Fraunces is reserved for the wordmark and section headers so it stays special.

---

## 3. Radius

Base scale is driven by one variable, `--radius: 0.5rem` (8px):

| Token          | Formula          | Value   |
| -------------- | ---------------- | ------- |
| `--radius-sm`  | `--radius - 4px` | 4px     |
| `--radius-md`  | `--radius - 2px` | 6px     |
| `--radius-lg`  | `--radius`       | **8px** |
| `--radius-xl`  | `--radius + 4px` | 12px    |
| `--radius-2xl` | `--radius + 8px` | 16px    |

**Usage reality** (counted across `src/`): `rounded-md` (40) and `rounded-sm` (19) dominate generic surfaces → the everyday card/input radius is **~6–8px**. But `rounded-full` is the single most-used value (47×) — **pill geometry is a signature**, not an afterthought: the top control cluster, mode toggles, the upsert/activity chips, status badges, and entity tags are all full-radius pills.

**Special case — the voice dock.** The Dynamic-Island-style capsule uses a fixed `rounded-[32px]` (not `rounded-full`) on purpose: at collapsed height (~60px) half-height ≈ 30px so it reads as a pill, but when it expands into a tall drawer a true `rounded-full` would balloon the corners into the text. 32px is the compromise. ([`src/routes/index.tsx:1314`](../src/routes/index.tsx))

**Port guidance:** two radius primitives — `8px` for rectangular surfaces, `StadiumBorder`/full for controls and chips; one `32px` for the voice capsule.

---

## 4. Shadows

Defined as tokens, intentionally minimal and **warm-tinted** (shadows use the ink hue at low alpha, never neutral black):

| Token            | Value                                     | Meaning                                                                                                                                                               |
| ---------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--shadow-paper` | `0 1px 2px ink/0.06, 0 8px 32px ink/0.08` | The workhorse. A tight contact shadow + a wide soft ambient one → paper resting on a warm surface. Used on every floating element (top pill, dock, chips, logo tile). |
| `--shadow-ink`   | `0 2px 0 ink/0.9`                         | A hard 2px offset, no blur — a crisp "printed/letterpress" edge. Reserved for emphasis.                                                                               |

Tailwind's stock `shadow-sm/md/lg` also appear (mostly inside vendored shadcn `ui/` primitives), but the app-authored surfaces consistently reach for `shadow-[var(--shadow-paper)]`. **Treat `--shadow-paper` as _the_ elevation.** Flutter: a `BoxShadow` list of two entries with the ink color at 6%/8% opacity — do **not** substitute Material's gray elevation shadows.

---

## 5. Texture & surface

This is what makes Lumen feel like paper, not an app — **do not flatten it in the port.**

- **Paper grain** — `--grain: radial-gradient(ink/0.03 1px, transparent 1px)` tiled at `background-size: 4px 4px` on `<body>`. A near-invisible dot field (3% ink) that gives the background tooth. iOS: a tiled 4×4 dot pattern or a subtle noise texture layer behind content.
- **Warm gradient** — `--gradient-warm: linear-gradient(135deg, paper, oklch(0.93 0.04 75))` available for hero/wash areas.
- **Layering via lightness, not lines** — cards are _lighter_ than paper and lift with `--shadow-paper`; borders are a low-contrast warm hairline (`--border`). Depth reads through light + soft shadow, not hard strokes.
- **Translucency** — floating chrome uses `bg-card/95` + `backdrop-blur` so the grain/graph shows faintly through. (iOS: a `BackdropFilter` blur — maps naturally to native materials.)
- **Antialiasing** — `-webkit-font-smoothing: antialiased` on body.

---

## 6. Motion (signature, port-relevant)

Defined in `styles.css`; all gated behind `@media (prefers-reduced-motion: reduce)` (honor the equivalent on iOS):

- `mic-pulse` / `mic-pulse-thoughtful` — expanding amber ring around the mic while recording / waiting. (1.6s urgent vs 2.6s calm.)
- `ink-rise` — content fades up 8px on entry (the "ink settling onto paper" entrance).
- `upsert-pop` — graph-update chips pop in with an amber ring that resolves into `--shadow-paper`.
- `agent-speaking` — amber ring pulse while the agent talks.
- **Mercury "goo" dock** — an SVG `feGaussianBlur`+`feColorMatrix` threshold filter fuses the voice capsule with drifting blob divs into one liquid-metal silhouette. **This is the hardest thing to port** — it relies on SVG filter primitives; Flutter would need a custom shader/`CustomPainter` metaball approximation. Flag as a dedicated port task, not a freebie.

All rings are amber at low alpha via `oklch(from var(--amber) l c h / α)` — the relative-color syntax means one accent drives every animation.

---

## 7. Port checklist (web → Flutter/iOS)

1. **Convert OKLCH → sRGB** for every token (§1 tables give approximations; compute exact values, don't eyeball). Build a single Dart `LumenColors` (or `ThemeExtension`) holding both light and dark sets.
2. **Reconcile the two palettes** — fold the hardcoded graph hex (§1 finding) into the same token table so chrome and graph share one source.
3. **Bundle fonts** — Fraunces (variable, with `ss01`/`ss02`) + Inter; keep Fraunces reserved for headers/wordmark.
4. **Radius:** `8px` rectangles, stadium/full controls, `32px` voice capsule.
5. **Elevation:** port `--shadow-paper` as a 2-layer warm `BoxShadow`; avoid Material gray shadows.
6. **Keep the texture:** grain dot-field + warm cards-lighter-than-paper + backdrop blur. Skipping this is what would make it "just another dark app."
7. **Motion:** reimplement the pulse/rise/pop easings; treat the mercury goo dock as its own R&D task.
