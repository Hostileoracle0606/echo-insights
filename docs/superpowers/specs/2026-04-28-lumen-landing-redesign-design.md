# Lumen Landing Page — Live-Component Redesign

**Date:** 2026-04-28
**Status:** Design approved, ready for implementation planning

## 1. Goal

Replace the static, AI-generated mockups in `code.html` (the design hand-off from
Stitch, captured in `Downloads/stitch_lumen_living_knowledge_graph/`) with a
production landing page that surfaces the actual signature components from the
Lumen app:

- The Dynamic-Island-style morphing dock pill in the **Effortless Capture** card
- An animated message exchange in the **Gentle Inquiry** card
- The real `d3-force-3d` knowledge graph in the **Crystalline Knowledge** card

The landing page becomes the new front door to the app and provides a single
"Begin Journey" CTA that hands the user off to the live experience.

## 2. Scope

### In scope

- Convert `/` (root route) of the existing `echo-insights` React app to render
  the new marketing landing page.
- Move the existing journal experience (currently mounted at `/`) to `/app`.
- Build three reusable, decoratively-animated landing widgets that wrap real
  app components.
- Wire CTAs (`Begin Journey` → `/app`, `Watch Film` → modal placeholder).
- Drop sections of the original mockup that don't reflect product reality
  (fake testimonials, dead nav links, "Join Waitlist" button).

### Out of scope

- Building the demo film referenced by `Watch Film` — the modal accepts a
  `videoUrl` prop and shows a placeholder until the URL is provided.
- Wiring real privacy / terms / journal guide / journal ethics destinations —
  the four footer links remain `href="#"` placeholders.
- Landing-page A/B testing infrastructure, analytics events, SEO meta-tag work
  beyond what already exists.
- Authentication, marketing email capture, waitlist functionality.
- Refactoring the marketing page's design system to share tokens with the
  app's `--paper` / `--ink` / `--amber` palette. The marketing page keeps the
  Stitch-defined gold/cream/Noto-Serif system from `DESIGN.md`.

## 3. Architecture

### File layout

```
echo-insights/src/routes/
  __root.tsx              (existing — shared shell, no changes)
  index.tsx               (existing journal — RENAME to app.tsx)
  app.tsx                 (NEW filename — same code as old index.tsx)
  landing.tsx             (NEW — marketing page, served at /)
  dock-preview.tsx        (existing — keep as is)

echo-insights/src/components/landing/
  effortless-capture-widget.tsx
  gentle-inquiry-widget.tsx
  crystalline-knowledge-widget.tsx
  video-modal.tsx
  dock-pill.tsx           (extracted from dock-preview.tsx)
  landing-graph-loop.tsx  (controller around <GraphView>)
  sample-data.ts          (canned transcripts + graph seed)
```

### Routing

TanStack Router with file-based route generation. Renaming
`src/routes/index.tsx` → `src/routes/app.tsx` regenerates `routeTree.gen.ts`
so:

| URL             | Component                        |
| --------------- | -------------------------------- |
| `/`             | `landing.tsx` (NEW)              |
| `/app`          | `app.tsx` (formerly `index.tsx`) |
| `/dock-preview` | unchanged                        |

The `Begin Journey` CTA uses `<Link to="/app">` for client-side navigation.

### Single bundle, single deploy

No infrastructure changes. The Vite build still emits one SPA bundle. The
landing page is just another route. Deployment, CI, hosting unchanged.

## 4. Page structure

Top to bottom:

| Block           | Treatment                                                                                                                                  |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Nav             | Trim. Lumen logo (left), `Begin Journey` button (right). No nav links, no `Join Waitlist`.                                                 |
| Hero            | Keep. Same headline, subhead, ambient gold orbs/glow. CTAs: `Begin Journey` and `Watch Film`.                                              |
| Bento grid      | Three glass cards, same layout as mockup (`md:col-span-2 + md:col-span-1` row 1, `md:col-span-3` row 2). New animated widgets inside each. |
| Voices of Lumen | **Removed.** No replacement.                                                                                                               |
| Footer          | Keep. `© {currentYear} Lumen`. Four placeholder hash-anchor links (Privacy, Terms, Journal Guide, Journal Ethics).                         |

### Visual system

The landing page uses the design tokens specified in
`Downloads/stitch_lumen_living_knowledge_graph/DESIGN.md` — gold primary
(`#D4AF37`, `#735c00`), warm whites, Noto Serif headings, Inter body,
glassmorphic surfaces. The widgets are themed to fit _into_ that system: gold
accents replace the app's amber, Noto Serif replaces Fraunces for landing-page
labels, glass cards replace the app's paper surface.

The widgets reuse the _structural_ code (state machines, force simulation, goo
SVG filter) but override visual tokens via Tailwind utility classes scoped to
the landing route.

## 5. Widget specifications

### 5.1 Effortless Capture — auto-cycling Dynamic Island

**Component:** `<EffortlessCaptureWidget />` wraps an extracted
`<DockPill mode={…} userText={…} agentText={…} />` (factored out of
`dock-preview.tsx`).

**State machine:** 12-second loop driven by a `useEffect` interval.

| Phase | Duration | Mode        | Visible content                                                                                      |
| ----- | -------- | ----------- | ---------------------------------------------------------------------------------------------------- |
| 1     | 1.0 s    | `idle`      | Collapsed narrow pill (180 px)                                                                       |
| 2     | 4.5 s    | `listening` | Mercury silhouette active. "You" speaker label. Transcript types in word-by-word at ~80 ms per word. |
| 3     | 1.5 s    | `thinking`  | "Mapping your thought…" with spinning loader                                                         |
| 4     | 4.0 s    | `speaking`  | Mercury silhouette active. "Lumen" label. Agent transcript types in.                                 |
| 5     | 1.0 s    | `idle`      | Collapsed → loop                                                                                     |

**Reused infrastructure:**

- The `#dock-goo` SVG filter from the production dock (`feGaussianBlur` +
  `feColorMatrix` threshold + `feMorphology` erode for the bumpy outline).
- The four `goo-blob` spans that fuse with the pill into the mercury
  silhouette.
- The width-and-height grid morph (`grid-template-rows: 0fr → 1fr`,
  `width: 180px → 560px`, eased with `cubic-bezier(0.34, 1.56, 0.64, 1)`).

**Theme overrides:**

- Active mic ring uses `#D4AF37` (gold) instead of `var(--accent)` (amber).
- Speaker labels render in Noto Serif (the marketing system) rather than
  Fraunces.
- Pill background: `bg-card` falls back to a Tailwind class that resolves to
  warm cream `#faf9f6`, indistinguishable from the app at a glance.

**Sample text** (already declared in `dock-preview.tsx`, reused via
`sample-data.ts` re-export):

- User: _"I had coffee with Maya this morning and she mentioned the Atlas
  migration is being delayed again, and honestly I'm not sure how I feel
  about it"_
- Agent: _"How long have you been turning this over with Maya?"_

### 5.2 Gentle Inquiry — animated bubbles

**Component:** `<GentleInquiryWidget />`. No canvas, no graph, just CSS +
React state.

**Behavior:** 7-second loop, three exchange pairs cycle through to avoid
robotic repetition.

| t (s) | Event                                                  |
| ----- | ------------------------------------------------------ |
| 0.0   | Both bubbles hidden (opacity 0, translateY 8 px)       |
| 0.3   | User bubble fades in + slides up (300 ms)              |
| 1.5   | Three pulsing dots appear inside an empty agent bubble |
| 3.0   | Dots are replaced by agent text, fades in (300 ms)     |
| 6.0   | Both bubbles fade out (200 ms) + slide down            |
| 7.0   | Loop restarts with the next exchange pair              |

**Exchange pairs:**

1. _"I felt overwhelmed by the project scope today."_ / _"What specific part
   of the scope feels heaviest right now?"_
2. _"I had coffee with Maya this morning."_ / _"How long have you been turning
   this over with her?"_
3. _"I keep thinking about the move."_ / _"What about it surfaces most
   often?"_

**Visual treatment** (matches the existing static mockup): user bubble
right-aligned in solid white with `rounded-tr-none`; agent bubble left-aligned
on `bg-secondary-container/30` with subtle border, `rounded-tl-none`; both
bubbles use `font-body-md text-body-md`.

### 5.3 Crystalline Knowledge — real force-directed graph

**Component:** `<CrystallineKnowledgeWidget />`, which renders
`<LandingGraphLoop>` — a controller wrapping the production `<GraphView>`.

**Reused infrastructure:** the full `src/components/graph-view.tsx`, including
`d3-force-3d` simulation, canvas rendering, `TYPE_COLORS` palette, and the
hand-drawn `drawNodeIcon` glyphs.

**Seed data** (declared in `sample-data.ts`):

| Entity          | Type     |
| --------------- | -------- |
| Maya            | person   |
| Atlas migration | project  |
| coffee shop     | place    |
| overwhelm       | emotion  |
| timeline        | concept  |
| Kai             | person   |
| design review   | event    |
| portfolio       | project  |
| weekend hike    | activity |
| Marin           | place    |

**Relations:**

```
Maya             — works_on            → Atlas migration
Maya             — met_at              → coffee shop
Maya             — collaborates_with   → Kai
Atlas migration  — blocked_by          → timeline
Atlas migration  — triggered           → overwhelm
Kai              — leads               → design review
design review    — shapes              → portfolio
portfolio        — due_after           → Atlas migration
weekend hike     — at                  → Marin
```

10 entities, 9 relations — dense enough to look alive, sparse enough not to
clutter the small card.

**Loop (15 s total):**

| Phase    | Duration | Behavior                                                                                                                        |
| -------- | -------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Stage in | 8.0 s    | One entity appears every 800 ms with a 600 ms scale-up + glow pulse. Relations snap into place when both endpoints are present. |
| Drift    | 6.0 s    | Simulation continues with `alphaTarget(0.05)` for gentle ambient motion.                                                        |
| Fade     | 1.0 s    | Whole canvas fades to opacity 0.                                                                                                |
| (loop)   | 0.0 s    | Reset, return to phase 1.                                                                                                       |

**Interactivity disabled.** The widget passes `onSelect={undefined}`, an
explicit `interactive={false}` prop is added to `<GraphView>` to disable
pointer handlers, hover highlights, and the drag-to-pan gesture. The graph is
purely presentational on the landing page — full interactivity remains on
`/app`.

**Sizing:** the card uses the same flex layout as the original mockup
(`flex-col md:flex-row`, text on the left, graph on the right at
`flex-1 aspect-video md:aspect-auto md:h-64`). The canvas resizes via
`ResizeObserver` (already implemented in `<GraphView>`), so narrow phone
widths render correctly.

**Theme:** `TYPE_COLORS` carries forward from the app
unchanged — it's already a warm earth-tone palette (orange persons, sage
places, gold projects) that harmonizes with the marketing aesthetic. The
graph background is transparent; the card's glass surface shows through.

## 6. CTAs and other wiring

### Begin Journey

`<Link to="/app">` from `@tanstack/react-router`. Renders as the gold pill in
the nav and the larger gold pill in the hero. Same component, two sizes.

### Watch Film

Triggers `<VideoModal videoUrl={null} />`. The modal:

- Renders an iframe / video element when `videoUrl` is non-null.
- Renders "Demo film coming soon" centered on a glass-card placeholder when
  `videoUrl` is null (current state until video lands).
- Closes on backdrop click, ESC key, and the `X` button.
- Uses `<Dialog>` from `src/components/ui/dialog.tsx` for accessibility.

When the video URL is ready, it's a one-line constant change in `landing.tsx`.

### Footer

Replace the hardcoded `© 2024` string with
`{`© ${new Date().getFullYear()} Lumen. A digital sanctuary for the human voice.`}`.
The four bottom links (Privacy, Terms, Journal Guide, Journal Ethics) remain
`href="#"` placeholders.

## 7. Reduced motion

All three widgets respect `prefers-reduced-motion: reduce` via a
`useReducedMotion()` hook.

| Widget                | Reduced-motion fallback                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Effortless Capture    | Pill renders statically expanded in `speaking` mode with the agent line displayed. No transitions, no goo blob animation. |
| Gentle Inquiry        | Both bubbles statically present with the first exchange pair. No fades, no looping.                                       |
| Crystalline Knowledge | Graph runs ONE simulation tick on mount then freezes (`alphaTarget(0)`). No entry stagger, no drift, no fade-loop.        |

## 8. Mobile behavior

The bento grid collapses to a single column at `< md` (Tailwind's 768 px
breakpoint), matching the original mockup. Per-widget mobile treatment:

| Widget                | Mobile treatment                                                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Effortless Capture    | Pill collapsed-min-width drops from 180 px to 140 px. Expanded-max-width clamps to `calc(100vw - 4rem)`.                        |
| Gentle Inquiry        | Bubbles reflow naturally; outer card padding tightens via existing Tailwind utilities.                                          |
| Crystalline Knowledge | Card stacks vertically: text on top, graph on bottom at `aspect-video`. Canvas autosizes through the existing `ResizeObserver`. |

## 9. Risks and mitigations

| Risk                                                                                                         | Mitigation                                                                                                                                                                    |
| ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `<GraphView>` couples tightly to journal-store types (`Entity`, `Relation`)                                  | Reuse those exact types in `sample-data.ts`. No type forking.                                                                                                                 |
| `dock-preview.tsx` was a private exploration — extracting `<DockPill>` may surface coupling we didn't notice | Read the route end-to-end during extraction; flag any dependency on `useGeminiLive` or `journal-store` and keep them inside the parent, not the extracted pill.               |
| Three concurrent loops on one page (dock 12 s, bubbles 7 s, graph 15 s) could thrash main-thread             | All animations CSS-driven where possible. The graph simulation already runs on `requestAnimationFrame`. Watch the perf profile during implementation.                         |
| Visitors hit `/` expecting the journal                                                                       | Stretch goal: detect `localStorage` evidence of a prior session (`journal-store` keys) and offer a "Resume your journal →" link in the nav. **Out of scope for this design.** |
| Routing rename breaks existing dev-tooling, bookmarks, deeplinks                                             | `index.tsx` → `app.tsx` is a self-contained rename. No external links are documented in the codebase. The `routeTree.gen.ts` regeneration is automatic.                       |

## 10. Success criteria

- `/` renders the new landing page with the three widgets running their loops.
- `/app` renders the existing journal experience, byte-identical behavior.
- `Begin Journey` navigates `/` → `/app` instantly (no full reload).
- `Watch Film` opens a modal with the placeholder; modal closes correctly.
- `prefers-reduced-motion` users see static fallbacks.
- Mobile (375 px width) renders without layout breakage in any of the three
  widgets.
- No regressions to `/dock-preview` or any other existing route.
- Vite production build succeeds; bundle-size delta is documented (graph view
  is already in the bundle, so the new widgets should add only their
  presentational code).
