# TEK Sound Assets

Drop short MP3/WAV files here matching these names. The app falls back to silent + haptic if a file is missing.

## Required slots

- `claim_xp.mp3` — XP claim. Should feel: deep synth pulse + subtle sub-bass swell. Like a power-up engaging in a tactical game.
- `tap.mp3` — UI tap. Should feel: cold mechanical click (steel/chain/relay click). 30-80ms. Used on tab switch + key buttons.
- `story_open.mp3` — Story open. Should feel: portal whoosh / subtle reverse swell. 150-300ms.
- `transmission.mp3` — Push notification arrived (in-app foreground). Radio-style transmission ping. 200-400ms.
- `relay.mp3` — XP transmission to a friend. Energy transfer / chain pull. 400-700ms.
- `redeem.mp3` — Reward redemption confirmed. Heavy mechanical chunk + green glow swell. 500-900ms.

## Sourcing

- Royalty-free industrial UI packs on Splice / Soundsnap / Freesound (search: "industrial UI", "sci-fi click", "vault click", "transmission").
- Or commission a short pack from a sound designer — match TEK's brand: cold, mechanical, ritualistic. Avoid bright/cheery/orchestral.

## Format

- MP3 (preferred) or WAV
- Mono is fine for UI clicks; stereo for moments (claim, redeem)
- Keep under 1 second (the app loads them on demand)
