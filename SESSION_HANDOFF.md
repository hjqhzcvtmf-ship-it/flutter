# TEK — Session Handoff (2026-06-02)

A complete brain-dump of the working session so another Claude session can pick up cold.
Covers: what TEK is (the soul), what got built this session, current repo/build state, and what's queued.

---

## 1. WHAT TEK IS (read this first — it's the why)

**TEK's core is humanity and real human connection.** Technology turned people into slaves to their
screens; TEK flips the tool back into service of being human — using tech to pull people OFF the phone
and INTO the room, to feel something real, to connect face-to-face again. The app is a deliberate
paradox: **technology whose entire job is to make you stop staring at technology.** The phone is the
map, not the destination. Radar/quests/levels are bait to make you look up — a quest only completes when
you do something real, in a real place, with real people.

**Purpose stack (bottom = soul, top = leverage):**
0. **Humanity / real connection** — the why beneath everything. Hold every feature against this. If a
   feature increases screen time for its own sake (infinite feed, doomscroll, notification spam), it's
   off-mission even if it "boosts engagement."
1. **Taste / curation** — what earns trust to gather people (the moat).
2. **Events** — where real connection happens; sponsor revenue; the founder's artist platform.
3. **App + franchise** — the tool that scales it without losing the soul (the leverage).

**Founder:** Lino Lyander — solo founder/developer of TEK (builds the whole thing: Flutter + Firebase +
Stripe + landing pages + App Store). Also a **Sony-signed EDM producer** with a new sound, releasing
music soon. TEK was born partly because he couldn't find a stage to play last year — he's building the
stage he couldn't find. Events are also his artist platform.

**Business model:** Events-first. First event April 2026 with sponsors **Monster Energy** + **Loop**
(nicotine pouches) — both loved it; Monster fits the green/black/chrome palette. Needs more sponsors.
Next event **June 27, 2026**. Cadence goal: monthly → biweekly. **Endgame: franchise** — organizers
worldwide throw parties under the TEK name using the app + features (radar, quests, levels) as the
defensible differentiator. Possibly festivals + global chapters.

**Musical identity (the concrete definition of "taste"):**
- Primary: **Awakenings festival** sound — dark, industrial, peak-time/hard/melodic techno. Aspires to
  book that calibre. Test: "Would this fit on an Awakenings stage?"
- Second axis: an **emo / emotional streak** — reference artist **RomancePlanet** (Adam James Fields,
  Miami; pop-punk/hyperpop emotional vocals fused with hard electronic). So TEK's sound is a spectrum:
  dark industrial techno threaded with emo emotional yearning. Unifying thread = **emotional intensity**
  (make people FEEL hard). Distinctive because most hard techno is cold; TEK runs real emotion through it.

**Aesthetic Bible (visual/sonic north star):** ~85-90% pure black, ~8-12% neon green `#00FF41` as ENERGY
not decoration, ~3-5% chrome/steel. NO warm tones, pastels, rounded/bubbly, cozy. Materials: industrial
cables, braided steel, chrome, matte black metal. Symbols: sigils, circuitry, vortex/portal, chains,
radial symmetry. Typography: machined, cold, minimal. Motion: precise/mechanical/fast (vault door, not
bouncy spring). Copy: terse, machined, ritualistic ("TRANSMISSION RECEIVED", "STAND BY"). Premium accent
#2 = cold chrome/steel, NEVER gold. Conceptual frame: gamifies the clubworld — members=operators,
venues=arenas, events=levels, missions=quests, drinks=loot. Every surface = tactical operator HUD.

> All of the above is also saved in persistent memory at
> `~/.claude/projects/-Users-linolyander-flutter-application-3tek/memory/` (files: tek_north_star,
> tek_business_events_strategy, user_profile, tek_aesthetic, project_overview, + others). A fresh
> Claude Code session loads the MEMORY.md index automatically.

---

## 2. TECH STACK & REPO

- **App:** Flutter (Dart). Effectively one giant file: `lib/app_main.dart` (~24k lines). Known debt;
  a modularization pass is worthwhile someday but risky — its own session.
- **Backend:** Firebase (Firestore, Auth, Storage, Cloud Functions Gen 2 nodejs22, App Check) — project
  `tek-nightclub-app`. Functions live in `cloud_functions/functions/index.js` (~5980 lines).
- **Payments:** Stripe. **AI:** Anthropic Claude (Haiku 4.5) via Cloud Functions, key in Functions Secret
  `ANTHROPIC_API_KEY`.
- **Version:** `pubspec.yaml` at `1.4.0+9` (build 9 is live in TestFlight).
- **Parallel sessions:** Lino runs multiple Claude sessions at once. ALWAYS `git log` / `git status`
  before declaring state — working tree can contain another session's uncommitted work.

---

## 3. WHAT SHIPPED THIS SESSION (all committed to `main`)

In rough order (newest last):
- `30c5ce14` **Badges: engraved sigil medallions on the trophy wall** — replaced 12 achievement badges'
  generic Material icons with procedural `_BadgeMedallionPainter` (brushed-metal rim, circuit notches,
  recessed plate, per-badge `_BadgeSigil` sigil). Earned = tier-color glow; locked = cold steel.
- `4493652c` **Engraved metal treatment** for tier chips / avatar glyphs / verification seals / reward
  icons via shared `_EngravedDisc` + `_TierChipPainter`. Also fixed brand drift: VIP tier off gold.
- `ad746396` **Profile/chat polish** — removed VIP tier entirely (+ TekVipCache), removed the
  "STAND BY / NO ACTIVE OBJECTIVES" empty hero card, added Challenges shortcut to ChatScreen + a
  send-message button on UserProfileView, fixed SidequestScreen having no back button when pushed.
- `91fd9306` **Admin: tappable event cards + check-in bypass without referralCode** (this was a parallel
  session's work, untangled from the working tree and committed cleanly) + bump to `1.4.0+9`.
- `45d5a36c` **Live friend social proof** — `TekSocialProof` singleton indexes friends'
  `completedSidequests`; sidequest cards + mission hero show "● N OPS HIT THIS". 5-min TTL.
- `00f165be` **Empty states that teach** — Radar (INVITE A FRIEND CTA), Challenges (long-press hint),
  Missions (tighter copy).
- `6526ea5f` **Long-press a friend row → quick-actions sheet** — `showMemberQuickActions()` with
  MESSAGE / CHALLENGES / VIEW PROFILE / RELAY XP. Wired onto the FRIENDLIST row only so far.
- `0d0d527b` **Smart mission hero (Claude subtitle)** — Cloud Function `heroSubtitle` (Haiku 4.5,
  deployed live) + `HeroSubtitleCache` Flutter singleton renders an AI TEK-voice subtitle under the
  mission hero title.
- `0967468b` **Disable smart hero subtitle by default** — `HeroSubtitleCache.enabled = false` kill
  switch. PAUSED FOR COST (see below). Function stays deployed (idle = free).

---

## 4. IMPORTANT STATE / GOTCHAS

- **AI hero is PAUSED.** `HeroSubtitleCache.enabled = false` in `lib/app_main.dart`. Lino paused it for
  Anthropic credit cost. BEFORE RE-ENABLING: do NOT just flip the flag. Switch to a **pre-compute
  pattern** — generate the subtitle ONCE at admin quest-create time, store on the Firestore quest doc,
  read for free on the client. That converts per-user-per-view cost into one-time-per-asset. The
  `heroSubtitle` function + its TEK-voice system prompt are reusable for that path.
- **Build/verify loop:** `flutter analyze lib/app_main.dart` (clean except pre-existing `unused_shown_name`
  on line 20). Simulator: `flutter run -d <iPhone 17 Pro sim id>`. First full iOS build is ~15 min;
  incremental ~40s. Sim sometimes needs `xcrun simctl boot <id>` first.
- **Firebase deploy:** `cd cloud_functions && firebase deploy --only functions:<name>`.
- **Git identity** is set repo-locally as `Lino Lyander <linolyander@icloud.com>`.

---

## 5. DESIGN SKILLS (installed by a parallel session, live NEXT session)

A design-skill suite was installed into `~/.claude/skills/`: official **frontend-design**,
**canvas-design**, plus **ui-ux-pro-max** and the **ckm:** set (brand, design, design-system, slides,
banner-design, ui-styling). They are NOT active in the session that wrote this file — skills load at
startup, so they come online in a fresh session. **frontend-design** + **ui-ux-pro-max** are built for
editing the TEK website; **canvas-design** does real PNG/PDF posters & social graphics.

---

## 6. QUEUED / NEXT MOVES

1. **TEK website edit** — best done in a fresh session where frontend-design + ui-ux-pro-max are live.
   Use the taste profile above (Awakenings + emo, green/black/chrome, North Star voice).
2. **June 27 event prep** — Lino wants to structure everything needed before the next event. App-side
   work I can drive: author the night's sidequests matched to physical venue artifacts (QR codes hidden
   on-site, code-entry passphrases, timer "stay on floor", friend_added recruit quests); schedule a
   loot drop at peak hour; test Radar at the venue (GPS varies in basements); door check-in QR dry run
   (admin bypass already shipped); flip the event `hidden → live` at announce time; pre-write the
   post-event "OPS REPORT" push. Still NEED from Lino: venue status, what's confirmed, biggest blocker.
3. **#4 First-event guided run** (AI-free onboarding flow for a new member's first real event) — biggest
   standalone product feature; queued.
4. **Extend long-press quick-actions** onto radar/search/chat-list rows (1-line edits, reuse
   `showMemberQuickActions`).
5. **Sponsorship** — Lino wants more sponsors/collaborators to fund events (Monster + Loop are the proof).
6. (Someday) modularize the 24k-line `app_main.dart`.

---

## 7. HOW TO USE THIS FILE

Paste this whole file into a fresh session, or just say "read SESSION_HANDOFF.md". A fresh Claude Code
session in this repo also auto-loads the persistent TEK memory, so the soul/strategy is already known —
this file adds the session-specific build state and queue that memory doesn't carry.
