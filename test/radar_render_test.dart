// Fast visual-iteration harness for the TEK Radar look.
// Renders 3 distinct directions straight to PNGs (no simulator):
//   flutter test test/radar_render_test.dart
//   open /tmp/radar_a.png /tmp/radar_b.png /tmp/radar_c.png
// Text labels omitted — flutter_test substitutes a box font; we judge the
// energy field here and keep labels in the app.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _green = Color(0xFF00FF41);
const _size = Size(590, 1278);

class _Blip {
  const _Blip(this.distanceMeters, this.absoluteBearingDeg);
  final double distanceMeters;
  final double absoluteBearingDeg;
}

const _blips = [_Blip(52, 35), _Blip(120, 200)];
const _maxRange = 150.0;

Offset _node(Offset center, double maxR, _Blip b, double headingDeg,
    double minR) {
  final rel = (b.absoluteBearingDeg - headingDeg) % 360.0;
  final ang = (rel - 90.0) * math.pi / 180.0;
  final distFrac = (b.distanceMeters / _maxRange).clamp(0.0, 1.0);
  final r = math.max(maxR * distFrac, minR);
  return center + Offset(math.cos(ang), math.sin(ang)) * r;
}

double _ang(_Blip b, double headingDeg) =>
    ((b.absoluteBearingDeg - headingDeg) % 360.0 - 90.0) * math.pi / 180.0;

void _vignette(Canvas canvas, Offset center, double strength) {
  canvas.drawRect(
    Offset.zero & _size,
    Paint()
      ..shader = RadialGradient(
        colors: [Colors.transparent, Colors.black.withValues(alpha: strength)],
        stops: const [0.55, 1.0],
      ).createShader(
        Rect.fromCircle(center: center, radius: _size.height * 0.62),
      ),
  );
}

void _orb(Canvas c, Offset p, double coreR, double haloR, double pulse) {
  c.drawCircle(
    p,
    haloR + 4 * pulse,
    Paint()
      ..color = _green.withValues(alpha: 0.12)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
  );
  c.drawCircle(
    p,
    coreR,
    Paint()
      ..shader = const RadialGradient(colors: [Colors.white, _green])
          .createShader(Rect.fromCircle(center: p, radius: coreR)),
  );
}

// ============================================================ A — NEBULA
// Fully organic plasma. No rings, no chevrons. Curved energy filaments,
// soft directional flares on a barely-there boundary, floating dust.
class _Nebula extends CustomPainter {
  _Nebula(this.t);
  final double t;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.min(size.width, size.height) * 0.46;
    final breathe = 0.5 + 0.5 * math.sin(t);

    // Volumetric core haze (two offset blooms = irregular plasma).
    for (final o in [const Offset(0, 0), const Offset(14, -10)]) {
      canvas.drawCircle(
        center + o,
        maxR * (0.9 + 0.05 * breathe),
        Paint()
          ..shader = RadialGradient(
            colors: [
              _green.withValues(alpha: 0.14),
              _green.withValues(alpha: 0.03),
              Colors.transparent,
            ],
            stops: const [0.0, 0.4, 0.9],
          ).createShader(Rect.fromCircle(center: center + o, radius: maxR)),
      );
    }

    // Floating dust — faint life in the field.
    final rnd = math.Random(7);
    for (var i = 0; i < 28; i++) {
      final a = rnd.nextDouble() * 2 * math.pi;
      final rr = rnd.nextDouble() * maxR;
      final p = center + Offset(math.cos(a), math.sin(a)) * rr;
      canvas.drawCircle(
        p,
        rnd.nextDouble() * 1.2 + 0.3,
        Paint()..color = _green.withValues(alpha: rnd.nextDouble() * 0.25),
      );
    }

    var phase = 0.0;
    for (final b in _blips) {
      final node = _node(center, maxR, b, 0, 36);
      final ang = _ang(b, 0);
      final pulse = 0.5 + 0.5 * math.sin(t + phase);
      phase += 2.4;

      // Curved filament (bowed bezier) core -> node.
      final mid = Offset.lerp(center, node, 0.5)!;
      final norm = Offset(-(node - center).dy, (node - center).dx);
      final ctrl = mid + (norm / norm.distance) * 26;
      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, node.dx, node.dy);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = _green.withValues(alpha: 0.30 + 0.15 * pulse)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );

      // Soft directional flare on the edge (organic, no chevron).
      final rim = center + Offset(math.cos(ang), math.sin(ang)) * maxR;
      canvas.drawCircle(
        rim,
        14,
        Paint()
          ..color = _green.withValues(alpha: 0.25 + 0.2 * pulse)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );

      _orb(canvas, node, 5, 17, pulse);
    }
    _orb(canvas, center, 8, 26, breathe);
    _vignette(canvas, center, 0.88);
  }

  @override
  bool shouldRepaint(_) => true;
}

// ============================================================ B — PORTAL
// Rotating vortex + a soft machined rim with one chrome highlight. Nodes are
// hot orbs; direction is a soft glowing arc on the rim (no hard chevron).
class _Portal extends CustomPainter {
  _Portal(this.t);
  final double t;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.min(size.width, size.height) * 0.46;
    final breathe = 0.5 + 0.5 * math.sin(t);
    final rect = Rect.fromCircle(center: center, radius: maxR);

    canvas.drawCircle(
      center,
      maxR * 1.2,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _green.withValues(alpha: 0.16),
            _green.withValues(alpha: 0.03),
            Colors.transparent,
          ],
          stops: const [0.0, 0.45, 0.92],
        ).createShader(Rect.fromCircle(center: center, radius: maxR * 1.2)),
    );

    // Rotating vortex.
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(t * 0.4);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawCircle(
      center,
      maxR,
      Paint()
        ..shader = SweepGradient(
          colors: [
            Colors.transparent,
            _green.withValues(alpha: 0.12),
            Colors.transparent,
            _green.withValues(alpha: 0.08),
            Colors.transparent,
          ],
          stops: const [0.0, 0.2, 0.45, 0.72, 1.0],
        ).createShader(rect)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 34),
    );
    canvas.restore();

    // Machined rim + breathing halo + chrome highlight.
    canvas.drawCircle(
      center,
      maxR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _green.withValues(alpha: 0.45),
    );
    canvas.drawCircle(
      center,
      maxR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = _green.withValues(alpha: 0.08 + 0.06 * breathe)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawArc(
      rect,
      math.pi * 1.05,
      0.55,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFFBFD2D6).withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1),
    );

    var phase = 0.0;
    for (final b in _blips) {
      final node = _node(center, maxR, b, 0, 34);
      final ang = _ang(b, 0);
      final pulse = 0.5 + 0.5 * math.sin(t + phase);
      phase += 2.4;

      canvas.drawLine(
        center,
        node,
        Paint()
          ..color = _green.withValues(alpha: 0.16)
          ..strokeWidth = 1.4
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      const lockSpan = 0.06 * 2 * math.pi;
      canvas.drawArc(
        rect,
        ang - lockSpan / 2,
        lockSpan,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..color = _green.withValues(alpha: 0.4 + 0.3 * pulse)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      _orb(canvas, node, 5, 17, pulse);
    }
    _orb(canvas, center, 8, 26, breathe);
    _vignette(canvas, center, 0.85);
  }

  @override
  bool shouldRepaint(_) => true;
}

// ============================================================ C — CONSTELLATION
// Restrained luxury. Near-black, lots of void. You + friends as crisp bright
// stars on thin elegant glowing lines. One whisper-soft boundary glow.
class _Constellation extends CustomPainter {
  _Constellation(this.t);
  final double t;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.min(size.width, size.height) * 0.46;
    final breathe = 0.5 + 0.5 * math.sin(t);

    // Whisper boundary glow — barely there.
    canvas.drawCircle(
      center,
      maxR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _green.withValues(alpha: 0.12 + 0.05 * breathe)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    // Faint central glow only.
    canvas.drawCircle(
      center,
      maxR * 0.5,
      Paint()
        ..shader = RadialGradient(
          colors: [_green.withValues(alpha: 0.07), Colors.transparent],
        ).createShader(Rect.fromCircle(center: center, radius: maxR * 0.5)),
    );

    var phase = 0.0;
    for (final b in _blips) {
      final node = _node(center, maxR, b, 0, 40);
      final ang = _ang(b, 0);
      final pulse = 0.5 + 0.5 * math.sin(t + phase);
      phase += 2.4;

      // Thin elegant connecting line.
      canvas.drawLine(
        center,
        node,
        Paint()
          ..color = _green.withValues(alpha: 0.22)
          ..strokeWidth = 0.8,
      );
      // Crisp tiny direction tick on the rim.
      final tickIn = center + Offset(math.cos(ang), math.sin(ang)) * (maxR - 6);
      final tickOut = center + Offset(math.cos(ang), math.sin(ang)) * (maxR + 6);
      canvas.drawLine(
        tickIn,
        tickOut,
        Paint()
          ..color = _green.withValues(alpha: 0.6 + 0.3 * pulse)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
      // Star: small bright core + tight glow.
      canvas.drawCircle(
        node,
        9,
        Paint()
          ..color = _green.withValues(alpha: 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawCircle(node, 3.5, Paint()..color = Colors.white);
      canvas.drawCircle(
        node,
        3.5,
        Paint()
          ..color = _green
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    // You: a clean bright star, slightly larger.
    canvas.drawCircle(
      center,
      14,
      Paint()
        ..color = _green.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawCircle(center, 5, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      5,
      Paint()
        ..color = _green
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    _vignette(canvas, center, 0.9);
  }

  @override
  bool shouldRepaint(_) => true;
}

Future<void> _render(WidgetTester tester, CustomPainter painter,
    String path) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: Container(
          width: _size.width,
          height: _size.height,
          color: Colors.black,
          child: CustomPaint(size: _size, painter: painter),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  testWidgets('render TEK radar variants', (tester) async {
    await tester.binding.setSurfaceSize(_size);
    const t = 0.16 * 2 * math.pi;
    await _render(tester, _Nebula(t), '/tmp/radar_a.png');
    await _render(tester, _Portal(t), '/tmp/radar_b.png');
    await _render(tester, _Constellation(t), '/tmp/radar_c.png');
  });
}
