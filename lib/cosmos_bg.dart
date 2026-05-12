import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TEK Void Background
// BLACK VOID + GREEN ENERGY + CHROME DUST + INDUSTRIAL
// Palette: Black 85-90% | Neon green 8-12% | Chrome/steel 3-5%
// ─────────────────────────────────────────────────────────────────────────────

const _tekGreen = Color(0xFF00FF41);
const _tekGreenDim = Color(0xFF003D10);
const _tekChrome = Color(0xFF8A8A8A);

/// A drifting green energy wisp — like a distant LED strip reflection.
class _EnergyWisp {
  double x, y, length, angle, speed, opacity, drift;
  _EnergyWisp({
    required this.x,
    required this.y,
    required this.length,
    required this.angle,
    required this.speed,
    required this.opacity,
    required this.drift,
  });
}

/// Chrome metallic dust particle — cold, tiny, barely visible.
class _ChromeDust {
  double x, y, radius, speed, opacity;
  _ChromeDust({
    required this.x,
    required this.y,
    required this.radius,
    required this.speed,
    required this.opacity,
  });
}

/// TEK animated background: pure black void with faint green energy traces,
/// drifting chrome dust, and a subtle radial vortex pull at center.
class CosmosBackground extends StatefulWidget {
  final bool intense;
  const CosmosBackground({super.key, this.intense = false});

  @override
  State<CosmosBackground> createState() => _CosmosBackgroundState();
}

class _CosmosBackgroundState extends State<CosmosBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late List<_EnergyWisp> _wisps;
  late List<_ChromeDust> _dust;
  final _rng = Random();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 120),
    )..repeat();

    _wisps = List.generate(widget.intense ? 8 : 5, (_) => _randomWisp());
    _dust = List.generate(widget.intense ? 30 : 18, (_) => _randomDust());
  }

  _EnergyWisp _randomWisp() => _EnergyWisp(
        x: _rng.nextDouble(),
        y: _rng.nextDouble(),
        length: _rng.nextDouble() * 0.08 + 0.02,
        angle: _rng.nextDouble() * 2 * pi,
        speed: (_rng.nextDouble() - 0.5) * 0.0002,
        opacity: _rng.nextDouble() * 0.06 + 0.02,
        drift: (_rng.nextDouble() - 0.5) * 0.0003,
      );

  _ChromeDust _randomDust() => _ChromeDust(
        x: _rng.nextDouble(),
        y: _rng.nextDouble(),
        radius: _rng.nextDouble() * 0.6 + 0.2,
        speed: _rng.nextDouble() * 0.001 + 0.0002,
        opacity: _rng.nextDouble() * 0.15 + 0.03,
      );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return CustomPaint(
          painter: _TekVoidPainter(
            wisps: _wisps,
            dust: _dust,
            tick: _ctrl.value,
            intense: widget.intense,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _TekVoidPainter extends CustomPainter {
  final List<_EnergyWisp> wisps;
  final List<_ChromeDust> dust;
  final double tick;
  final bool intense;

  _TekVoidPainter({
    required this.wisps,
    required this.dust,
    required this.tick,
    required this.intense,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── PURE BLACK VOID ──
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.black,
    );

    final cx = size.width / 2;
    final cy = size.height * 0.38;
    final time = tick * 2 * pi;

    // ── VORTEX PULL — very subtle radial green glow at center ──
    final vortexBreath = 0.5 + 0.5 * sin(time * 0.3);
    final vortexAlpha = (0.03 + 0.02 * vortexBreath).clamp(0.0, 1.0);
    final vortexPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          _tekGreenDim.withValues(alpha: vortexAlpha),
          _tekGreenDim.withValues(alpha: vortexAlpha * 0.3),
          Colors.transparent,
        ],
        stops: const [0.0, 0.4, 1.0],
      ).createShader(
        Rect.fromCircle(center: Offset(cx, cy), radius: size.width * 0.5),
      );
    canvas.drawCircle(Offset(cx, cy), size.width * 0.5, vortexPaint);

    // ── ENERGY WISPS — faint green laser-like traces drifting slowly ──
    for (final w in wisps) {
      final wx = ((w.x + w.drift * tick * 2000) % 1.1) - 0.05;
      final wy = ((w.y + w.speed * tick * 2000) % 1.1) - 0.05;
      final flicker = (sin(time * 1.5 + w.angle * 10) + 1) / 2;
      final alpha = (w.opacity * (0.5 + 0.5 * flicker)).clamp(0.0, 1.0);

      final start = Offset(wx * size.width, wy * size.height);
      final end = Offset(
        start.dx + cos(w.angle) * w.length * size.width,
        start.dy + sin(w.angle) * w.length * size.height,
      );

      final wispPaint = Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            _tekGreen.withValues(alpha: alpha),
            Colors.transparent,
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromPoints(start, end))
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke;
      canvas.drawLine(start, end, wispPaint);

      // Faint glow around the wisp midpoint
      final mid = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
      final glowPaint = Paint()
        ..color = _tekGreen.withValues(alpha: (alpha * 0.3).clamp(0.0, 1.0))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(mid, 4, glowPaint);
    }

    // ── CHROME DUST — cold metallic specs drifting upward slowly ──
    for (final d in dust) {
      final dy = (d.y - d.speed * tick * 800) % 1.0;
      final flicker = (sin(time * 2 + d.x * 50) + 1) / 2;
      final alpha = (d.opacity * (0.3 + 0.7 * flicker)).clamp(0.0, 1.0);

      final pos = Offset(d.x * size.width, dy * size.height);
      final dustPaint = Paint()
        ..color = _tekChrome.withValues(alpha: alpha);
      canvas.drawCircle(pos, d.radius, dustPaint);
    }

    // ── FAINT GRID LINES — industrial circuit traces ──
    final gridPaint = Paint()
      ..color = _tekGreen.withValues(alpha: 0.012)
      ..strokeWidth = 0.3
      ..style = PaintingStyle.stroke;

    // Horizontal lines
    final gridSpacing = size.height / 20;
    for (int i = 0; i < 20; i++) {
      final y = i * gridSpacing;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    // Vertical lines
    final vSpacing = size.width / 12;
    for (int i = 0; i < 12; i++) {
      final x = i * vSpacing;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _TekVoidPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Premium Page Transition
// ─────────────────────────────────────────────────────────────────────────────

/// Fade + slight scale-up + slide from bottom transition.
Route<T> cosmosPageRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 500),
    reverseTransitionDuration: const Duration(milliseconds: 400),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(curved),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Glassmorphic Card Wrapper
// ─────────────────────────────────────────────────────────────────────────────

/// A card with frosted glass effect, subtle glow border, and shadow.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double borderRadius;
  final Color? glowColor;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.borderRadius = 16,
    this.glowColor,
  });

  @override
  Widget build(BuildContext context) {
    final glow = glowColor ?? const Color(0xFF00FF41);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: glow.withValues(alpha: 0.08),
            blurRadius: 24,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              color: Colors.white.withValues(alpha: 0.06),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.1),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Glowing Button
// ─────────────────────────────────────────────────────────────────────────────

/// A premium button with a pulsating glow and scale-on-press animation.
class GlowButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final String label;
  final Color color;
  final double width;
  final double height;
  final bool isLoading;
  final IconData? icon;

  const GlowButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.color = const Color(0xFF00FF41),
    this.width = 200,
    this.height = 52,
    this.isLoading = false,
    this.icon,
  });

  @override
  State<GlowButton> createState() => _GlowButtonState();
}

class _GlowButtonState extends State<GlowButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _glowCtrl;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glowCtrl,
      builder: (context, child) {
        final glowAlpha = 0.15 + 0.15 * _glowCtrl.value;
        return GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) {
            setState(() => _pressed = false);
            widget.onPressed?.call();
          },
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed ? 0.95 : 1.0,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: widget.width,
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: widget.color.withValues(alpha: 0.7),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: glowAlpha),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    widget.color.withValues(alpha: 0.15),
                    widget.color.withValues(alpha: 0.05),
                  ],
                ),
              ),
              child: Center(
                child: widget.isLoading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(widget.color),
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.icon != null) ...[
                            Icon(widget.icon, color: widget.color, size: 20),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            widget.label,
                            style: TextStyle(
                              color: widget.color,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stagger-Animated List Item
// ─────────────────────────────────────────────────────────────────────────────

/// Wrap list children in this to get a cascading fade-in + slide-up effect.
class StaggerItem extends StatefulWidget {
  final int index;
  final Widget child;
  const StaggerItem({super.key, required this.index, required this.child});

  @override
  State<StaggerItem> createState() => _StaggerItemState();
}

class _StaggerItemState extends State<StaggerItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    // Stagger delay based on index
    Future.delayed(Duration(milliseconds: 60 * widget.index), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Floating Cosmos Scaffold  (convenience wrapper)
// ─────────────────────────────────────────────────────────────────────────────

/// A Scaffold with the animated cosmos background behind its body.
/// Use this in place of a normal [Scaffold] for any screen.
class CosmosScaffold extends StatelessWidget {
  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final bool intense;

  const CosmosScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.intense = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: appBar,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      body: Stack(
        children: [
          const Positioned.fill(child: CosmosBackground()),
          Positioned.fill(child: body),
        ],
      ),
    );
  }
}
