import 'package:flutter/material.dart';

/// TEK — Design Tokens (single source of truth, Flutter side).
///
/// Mirror of `tokens.css` — keep both in sync.
/// Visual formula: black void + metallic structure + green energy + symmetry/vortex.
///
/// Color ratio discipline (strict): ~85–90% void, ~8–12% signal green,
/// ~3–5% chrome/steel. No warm tones, no gold-as-luxury.
///
/// Everything here is `const` so call sites keep `const TextStyle(...)` and
/// `const BoxDecoration(...)` — losing const-ness across a 27k-line file
/// would cost real rebuild performance.
class TekColors {
  TekColors._();

  // ── Surfaces (~85–90% of every screen) ──────────────────────────
  /// App background, deepest surface.
  static const Color void_ = Color(0xFF0D0D1A);

  /// Pure black — overlays, scrims.
  static const Color black = Color(0xFF000000);

  /// Raised cards, sheets, dialogs.
  static const Color surface = Color(0xFF1A1A1A);

  /// Inset / pressed surface.
  static const Color surface2 = Color(0xFF131313);

  /// Sheets, dialogs, nav — the app's established deep chrome surface.
  static const Color surfaceDeep = Color(0xFF0A0A0A);

  /// Lifted fill — image placeholders, avatar backgrounds, inert blocks.
  /// The cold replacement for Material's warm `Colors.grey[800]`.
  static const Color surfaceLift = Color(0xFF2A2C33);

  // ── Signal green (~8–12%) — ENERGY, not decoration ──────────────
  /// PRIMARY: active state, focus, brand, primary CTA.
  static const Color signal = Color(0xFF00FF41);

  // ── Chrome / steel (~3–5%) ──────────────────────────────────────
  /// Primary body / secondary text (cool, never warm).
  static const Color steel = Color(0xFFB8B8C0);

  /// Borders, dividers, muted labels.
  static const Color chrome = Color(0xFF7A7A7A);

  /// Polished-metal highlights, premium/elite accents.
  static const Color silver = Color(0xFFC0C0C0);

  /// Dark machined metal — the low end of the cold-metal ramp.
  /// Replaces bronze in tier/medal hierarchies.
  static const Color gunmetal = Color(0xFF6E7480);

  /// Brightest cold metal. Replaces gold as the top non-energy tier.
  static const Color platinum = Color(0xFFE8ECF4);

  /// The cold-metal status ladder, lowest to highest.
  ///
  /// gunmetal → silver → platinum → signal
  ///
  /// Signal green stays the apex: the top of the ladder is *energy*, not
  /// metal. Everything below it is machined and cold. No gold, ever —
  /// gold reads as participation trophy; cold metal reads as earned access.
  static const List<Color> tierLadder = [gunmetal, silver, platinum, signal];

  // ── State ───────────────────────────────────────────────────────
  /// Errors, destructive actions, expired states.
  static const Color danger = Color(0xFFFF0000);

  // ── Signal glow alphas (glow, not fill) ─────────────────────────
  static const Color glowSoft = Color(0x4000FF41); // 25%
  static const Color glowMid = Color(0x6600FF41); // 40%
  static const Color glowStrong = Color(0x9900FF41); // 60%
  static const Color borderSignal = Color(0xB300FF41); // 70%
  static const Color borderChrome = Color(0x597A7A7A); // chrome @ 35%

  // 🚫 Banned: gold (0xFFFFD700) / bronze (0xFFCD7F32) as luxury.
  // Premium/elite states use chrome/silver/gunmetal only. See TekTier.
}

/// Cold ink ramp — the replacement for `Colors.white*`.
///
/// Pure white (#FFFFFF) on near-black is the harshest possible pairing and
/// reads cheap. Every value here is the SAME alpha as its Material
/// counterpart, with only the RGB shifted cold (R=G, B+10 — the same hue
/// relationship as steel #B8B8C0). That makes the migration a provably
/// contrast-preserving 1:1 swap: hierarchy and compositing are untouched,
/// the glare and the warmth are not.
///
/// | Material        | TekInk      | alpha |
/// |-----------------|-------------|-------|
/// | `Colors.white`  | `TekInk.high`   | FF |
/// | `Colors.white70`| `TekInk.body`   | B3 |
/// | `Colors.white60`| `TekInk.subtle` | 99 |
/// | `Colors.white54`| `TekInk.muted`  | 8A |
/// | `Colors.white38`| `TekInk.faint`  | 62 |
/// | `Colors.white30`| `TekInk.dim`    | 4D |
/// | `Colors.white24`| `TekInk.line`   | 3D |
/// | `Colors.white12`| `TekInk.hairline` | 1F |
/// | `Colors.white10`| `TekInk.wash`   | 1A |
class TekInk {
  TekInk._();

  /// The cold base. Retune the whole app's ink from this one value.
  static const Color base = Color(0xFFE4E4EE);

  /// High-emphasis: headings, active icons, primary text.
  static const Color high = Color(0xFFE4E4EE);

  /// Body text. Lands on the brand's steel when composited on void.
  static const Color body = Color(0xB3E4E4EE);

  /// Subtle body.
  static const Color subtle = Color(0x99E4E4EE);

  /// Secondary / muted labels.
  static const Color muted = Color(0x8AE4E4EE);

  /// Tertiary, hints, disabled text.
  static const Color faint = Color(0x62E4E4EE);

  /// Very low emphasis text and inactive icons.
  static const Color dim = Color(0x4DE4E4EE);

  /// Visible borders and dividers.
  static const Color line = Color(0x3DE4E4EE);

  /// Hairline borders.
  static const Color hairline = Color(0x1FE4E4EE);

  /// Subtle fills and washes.
  static const Color wash = Color(0x1AE4E4EE);
}

/// Typography tokens — industrial, machined, uppercase, wide-tracked.
class TekType {
  TekType._();

  static const String fontUi = 'Inter';

  /// Codes, IDs, QR payloads, telemetry, timers.
  /// TODO(phase-4): swap to a bundled mono so this stops resolving to
  /// Courier on iOS and Droid Sans Mono on Android.
  static const String fontMono = 'monospace';

  // Letter-spacing — uppercase labels feel machined.
  static const double trackBody = 0.0;
  static const double trackTight = 0.5;
  static const double trackWide = 1.0;
  static const double trackLabel = 2.0; // labels, tabs, status
  static const double trackCta = 3.0; // hero / primary CTA

  static const FontWeight weightLabel = FontWeight.bold;
  static const FontWeight weightBody = FontWeight.normal;

  // Type scale (logical px).
  //
  // `micro` is the FLOOR. Nothing ships below it — TEK is read at arm's
  // length, in the dark, one-handed, while moving. 7–9px type is decoration,
  // not information.
  static const double micro = 11.0;
  static const double label = 13.0;
  static const double body = 15.0;
  static const double subtitle = 18.0;
  static const double title = 22.0;
  static const double display = 32.0;
}

/// Ready-made text styles. Prefer these over inline `TextStyle(...)` so
/// typography has a single seam to change through.
class TekText {
  TekText._();

  /// Micro label — status chips, captions, timestamps. UPPERCASE.
  static const TextStyle micro = TextStyle(
    fontSize: TekType.micro,
    fontWeight: TekType.weightLabel,
    letterSpacing: TekType.trackLabel,
    color: TekInk.muted,
  );

  /// Standard UI label — buttons, tabs, section headers. UPPERCASE.
  static const TextStyle label = TextStyle(
    fontSize: TekType.label,
    fontWeight: TekType.weightLabel,
    letterSpacing: TekType.trackLabel,
    color: TekInk.body,
  );

  /// Primary CTA label — widest tracking.
  static const TextStyle cta = TextStyle(
    fontSize: TekType.label,
    fontWeight: TekType.weightLabel,
    letterSpacing: TekType.trackCta,
    color: TekColors.signal,
  );

  /// Body copy — the only style with normal tracking.
  static const TextStyle body = TextStyle(
    fontSize: TekType.body,
    fontWeight: TekType.weightBody,
    letterSpacing: TekType.trackBody,
    color: TekInk.body,
  );

  /// Screen / section title.
  static const TextStyle title = TextStyle(
    fontSize: TekType.title,
    fontWeight: TekType.weightLabel,
    letterSpacing: TekType.trackLabel,
    color: TekInk.high,
  );

  /// Hero display type.
  static const TextStyle display = TextStyle(
    fontSize: TekType.display,
    fontWeight: TekType.weightLabel,
    letterSpacing: TekType.trackCta,
    color: TekInk.high,
  );

  /// Codes, IDs, QR payloads, telemetry, timers. Always mono.
  static const TextStyle mono = TextStyle(
    fontFamily: TekType.fontMono,
    fontSize: TekType.body,
    fontWeight: TekType.weightLabel,
    letterSpacing: TekType.trackWide,
    color: TekColors.signal,
  );
}

/// Motion tokens — precise, mechanical, fast (vault door, not bouncy spring).
class TekMotion {
  TekMotion._();

  static const Duration instant = Duration(milliseconds: 80);
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 400);

  /// The TEK easing. Fast out of the gate, hard settle — a vault door.
  static const Cubic easeMechanical = Cubic(0.2, 0, 0, 1);

  /// 🚫 Never `Curves.elasticOut` / `bounceOut` — springs are off-brand.
}

/// Border / radius tokens — engineered, minimal.
///
/// TEK is equipment, not a consumer social app. Soft 12px corners are the
/// shape language of Instagram and banking apps; 4px reads as machined.
class TekShape {
  TekShape._();

  /// Chips, badges, inline markers.
  static const double radiusTight = 2.0;

  /// THE radius. Cards, buttons, sheets, inputs, dialogs.
  static const double radius = 4.0;

  /// Large surfaces only — full-bleed sheets, modals.
  static const double radiusLarge = 8.0;

  /// Genuine pills and circles (avatars, indicator dots). Not a card radius.
  static const double pill = 999.0;

  /// Card / divider hairline.
  static const double hairline = 0.6;

  /// Emphasis border — active states, focused inputs.
  static const double border = 1.0;

  // Ready-made BorderRadius — const, so decorations stay const.
  static const BorderRadius brTight = BorderRadius.all(Radius.circular(radiusTight));
  static const BorderRadius br = BorderRadius.all(Radius.circular(radius));
  static const BorderRadius brLarge = BorderRadius.all(Radius.circular(radiusLarge));
  static const BorderRadius brPill = BorderRadius.all(Radius.circular(pill));

  /// Top-rounded, for bottom sheets.
  static const BorderRadius brSheet = BorderRadius.vertical(top: Radius.circular(radiusLarge));
}

/// Spacing scale — 4pt grid. Use these instead of arbitrary numbers.
class TekSpace {
  TekSpace._();

  static const double xxs = 2.0;
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 24.0;
  static const double xxl = 32.0;
  static const double huge = 48.0;

  /// Minimum touch target. Below this is not tappable in a dark, moving room.
  static const double tapTarget = 44.0;

  // Common gaps — const, cheap, readable.
  static const SizedBox gapXs = SizedBox(height: xs);
  static const SizedBox gapSm = SizedBox(height: sm);
  static const SizedBox gapMd = SizedBox(height: md);
  static const SizedBox gapLg = SizedBox(height: lg);
  static const SizedBox gapXl = SizedBox(height: xl);

  // Standard insets.
  static const EdgeInsets screen = EdgeInsets.symmetric(horizontal: lg);
  static const EdgeInsets card = EdgeInsets.all(lg);
  static const EdgeInsets cardTight = EdgeInsets.all(md);
}
