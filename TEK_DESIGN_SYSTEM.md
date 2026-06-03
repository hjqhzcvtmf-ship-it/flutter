# TEK — Design System

> Single source of truth for Claude Design, Figma, and any TEK surface.
> TEK is not "fun" — TEK is **magnetic**. Emotional target: tension + curiosity + submission + awe.
> Never hype, never friendly, never warm. Mission-control HUD over real nightlife — not a social app.

---

## 1. Visual Formula (every screen must satisfy this)

> **black void + metallic structure + green energy source + symmetry or vortex**

If one is missing → it's off-brand. Reject it.

---

## 2. Color

Strict ratio discipline — this is the law, not a suggestion:

- **~85–90%** pure black / void
- **~8–12%** neon signal green — used as ENERGY, not decoration
- **~3–5%** chrome / steel highlights
- 🚫 No warm tones, no rainbow gradients, no pastels, no cozy ambience, no gold-as-luxury

### Core tokens (pulled from the live app)

| Token | Hex | Role |
|---|---|---|
| `--tek-void` | `#0D0D1A` | App background, deepest surface |
| `--tek-black` | `#000000` | Pure black, overlays, scrims |
| `--tek-surface` | `#1A1A1A` | Raised cards, sheets, dialogs |
| `--tek-surface-2` | `#131313` | Inset / pressed surface |
| `--tek-signal` | `#00FF41` | PRIMARY. Energy, active state, focus, brand |
| `--tek-steel` | `#B8B8C0` | Primary body/secondary text (cool, never warm) |
| `--tek-chrome` | `#7A7A7A` | Borders, dividers, muted labels |
| `--tek-silver` | `#C0C0C0` | Polished-metal highlights, premium accents |
| `--tek-danger` | `#FF0000` | Errors, destructive, expired states |

### Signal-green usage rules
- Glow, not fill. Prefer `box-shadow`/blur halos (`#00FF41` @ 0.25–0.6 alpha) over solid green blocks.
- Solid `#00FF41` only for: primary CTA, active tab indicator, "live/engaged" status.
- Borders use green at **0.4–0.7 alpha**, never full opacity, except active CTAs.

### Banned / legacy (do not introduce; migrate out where seen)
`#FFD700` gold and `#CD7F32` bronze appear in legacy reward tiers — **gold is off-brand** as luxury. Premium/elite states must use **cold metallics** (chrome `#7A7A7A`, silver `#C0C0C0`), never gold or warm yellow.

---

## 3. Typography

Industrial, stretched, engineered, cold, minimal. Letters should feel **machined**, not designed. No handwritten / rounded / bubbly.

| Token | Family | Use |
|---|---|---|
| `--tek-font-ui` | Inter | All UI text, body, labels |
| `--tek-font-mono` | monospace | Codes, IDs, QR payloads, telemetry, timers |

### Type rules
- **UPPERCASE + wide tracking** for all labels, buttons, tab labels, status.
- Letter-spacing scale: labels `2–3`, hero/CTA `3`, body `0–0.5`.
- Weight: `bold` (700) for labels/CTAs; regular for body.
- Sizes: micro-label 10–12 / label 12–14 / body 14–16 / title 18–24.

---

## 4. Voice & Copy

Terse, machined, slightly ritualistic. Mission-control language — never "feed" / "notifications" / casual.

- ✅ `TRANSMISSION RECEIVED` · `STAND BY` · `RELAY ENGAGED` · `REQUEST SENT — AWAITING ACCEPT` · `REDEEMED`
- 🚫 "Yay!" · "Oops!" · "You're all set 😊" · emoji-warm tone
- Members are **players**, venues are **arenas**, events are **levels**, missions are **quests**, drinks are **loot**, crews are **guilds**.

---

## 5. Material & Motion

- **Material vocabulary:** braided steel, pipes, chain links, polished chrome, matte black metal. If it isn't cold, heavy, or mechanical → don't ship it.
- **Lighting:** functional or ominous only — lasers, tunnel lights, LED strips, spotlight cones, portal glow. No sunlight, no cozy ambient.
- **Motion:** precise, mechanical, fast — like a vault door, not a bouncy spring. Compositor-friendly only (`transform`, `opacity`, `filter`). Glow-pulse on active energy elements.
- **Spatial mood:** underground facility, brutalist machine room, tunnels. The user should feel pulled in, not comfortable.

---

## 6. Component conventions

- **Buttons / CTAs:** black fill, `#00FF41` border + glow, uppercase wide-tracked label. Active = solid green fill, black text.
- **Cards / surfaces:** `#1A1A1A` on `#0D0D1A`, hairline chrome border (`#7A7A7A` @ 0.35, 0.6px), optional green glow when "live."
- **Tabs:** label color `#00FF41` active / `#7A7A7A` inactive, green indicator.
- **Status flashes:** green = success/engaged, red = error/expired, steel = neutral.
- **QR / scanner:** green corner brackets, monospace payload.

---

## 7. Symbol language

Engineered, ritualistic, alien-tech, sharp, symmetrical: sigils, circuitry, mechanical geometry, vortex/portal shapes, chain forms, radial symmetry.
**North-star anchor:** the green-vortex + chrome + chain logo/poster.

Human imagery = silhouettes, obscured faces, motion blur, green light wash. Members are participants, not subjects. No influencer photos.
