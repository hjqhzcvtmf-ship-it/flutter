# TEK 1.4.0 — Release Notes

## Short version (recommended for App Store "What's New" — ~600 chars)

```
A major upgrade to the TEK experience.

• New 8-tier reward ladder — earn free drinks, guest passes, free tickets, VIP entry and more as you level up
• Tier-gated lounges — unlock private channels at higher levels
• Polished profiles with badges, stats and live XP progression
• Stories — share 24-hour photo posts with the community
• Photo messages in DMs
• Going list on events — see who's coming
• Daily streaks with bonus XP
• Add friends instantly by QR
• Redeem rewards in-app

Plus a redesigned first-launch experience and dozens of small polish improvements.
```

---

## Longer version (if you want one for a TestFlight test-notes panel or a launch tweet)

```
TEK 1.4.0 — Operator Update

The biggest TEK release yet. Everything is more connected.

PROGRESSION
• An 8-tier reward ladder: free drinks, guest passes, free tickets, VIP entry, reserved booths, all the way up to BLACK CARD
• Every completed mission moves you up. Unlock real perks.

LOUNGES
• Higher-tier members unlock the INNER CIRCLE and BLACK CARD lounges — invite-only channels for the operators above level 40 and 60

MISSIONS
• Loot-drop missions appear during live events — time-limited, high-XP
• Mission combos: complete three in one night for a bonus
• Daily and weekly mission rotation keeps it fresh

SOCIAL
• Stories — 24-hour photo posts, just like you expect
• Photo messages in private chats
• See who's GOING to every event
• Add friends instantly by scanning their TEK QR

PROFILE
• A redesigned profile with live XP bar, tier badges, and the full trophy wall
• Public profiles show level and stats so members can recognise each other

DAILY
• Streaks reward consecutive-day check-ins
• Push notifications you can fully control in Settings

REWARDS
• Reach 100 XP and a free drink redemption appears on your profile
• Show the QR to a bartender at any TEK event

PLUS
• A new welcome film when you first open the app
• Hundreds of polish improvements
• Account deletion from Settings (because the App Store demanded it, fair enough)

WELCOME, OPERATOR.
```

---

## Internal changelog (for your records — do not paste to App Store)

See `git log v1.3.0..HEAD` for the full picture. High-level:

- 8-tier reward ladder + redemption flow
- Tier identity (FOUNDER / VIP) + tier-color avatars
- Tier-gated chat lounges (INNER CIRCLE / BLACK CARD)
- Quests v2: server-authoritative claim, daily/weekly rotation, mission combos, loot-drop missions
- AI mission drafting (single + batch of 5) via Anthropic Haiku 4.5
- Stories with 24h expiry, fullscreen viewer with progress bars
- Photo messages in private chat (gallery picker + Storage)
- Event RSVPs (GOING list with avatar grid)
- QR friend-add (profile QR + scanner)
- Daily login streak (+5/day, +25 at 7-day milestone)
- Polished public profile (badge wall, live XP bar, stat row)
- TEK aesthetic helpers: sound system, frosted glass, press-state spring
- 3-panel onboarding film on first launch
- Empty-state copy rewritten in TEK voice
- Account deletion + per-type notification preferences
- Firestore rules updates for all new collections
- Cloud Functions: claimQuestXP, generateQuestWithAI, generateQuestBatchWithAI, daily/weekly/streak schedulers, inbox mirror writes
