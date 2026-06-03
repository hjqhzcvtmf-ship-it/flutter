import 'package:flutter/material.dart';

/// TEK — Design Tokens (single source of truth, Flutter side).
///
/// Mirror of `tokens.css` — keep both in sync.
/// Visual formula: black void + metallic structure + green energy + symmetry/vortex.
///
/// Color ratio discipline (strict): ~85–90% void, ~8–12% signal green,
/// ~3–5% chrome/steel. No warm tones, no gold-as-luxury.
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

  // ── State ───────────────────────────────────────────────────────
  /// Errors, destructive actions, expired states.
  static const Color danger = Color(0xFFFF0000);

  // ── Signal glow alphas (glow, not fill) ─────────────────────────
  static Color glowSoft = signal.withValues(alpha: 0.25);
  static Color glowMid = signal.withValues(alpha: 0.40);
  static Color glowStrong = signal.withValues(alpha: 0.60);
  static Color borderSignal = signal.withValues(alpha: 0.70);
  static Color borderChrome = chrome.withValues(alpha: 0.35);

  // 🚫 Banned: gold (0xFFFFD700) / bronze as luxury.
  // Premium/elite states use chrome/silver only.
}

/// Typography tokens — industrial, machined, uppercase, wide-tracked.
class TekType {
  TekType._();

  static const String fontUi = 'Inter';
  static const String fontMono = 'monospace';

  // Letter-spacing — uppercase labels feel machined.
  static const double trackLabel = 2.0; // labels, tabs, status
  static const double trackCta = 3.0; // hero / primary CTA
  static const double trackBody = 0.0;

  static const FontWeight weightLabel = FontWeight.bold;
  static const FontWeight weightBody = FontWeight.normal;

  // Type scale (logical px).
  static const double micro = 11.0;
  static const double label = 13.0;
  static const double body = 15.0;
  static const double title = 22.0;
}

/// Motion tokens — precise, mechanical, fast (vault door, not bouncy spring).
class TekMotion {
  TekMotion._();

  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 240);
  static const Cubic easeMechanical = Cubic(0.2, 0, 0, 1);
}

/// Border / radius tokens — engineered, minimal.
class TekShape {
  TekShape._();

  static const double radius = 4.0;
  static const double hairline = 0.6;
}
