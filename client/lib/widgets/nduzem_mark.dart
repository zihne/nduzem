import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The "frosted O" brand mark, drawn rather than bundled.
///
/// Same geometry as `assets/branding/logo.svg` and therefore the same
/// shape as the launcher icon and the favicon: a ring split along the
/// NW/SE diagonal, the top-right arc in Deep Purple 500 and the
/// bottom-left in Deep Purple 100. Reads as the letter O and ties the
/// name to a two-tone opacity split.
///
/// Drawn with two arcs instead of shipping the asset for three reasons:
/// nothing has to be added to `pubspec.yaml` (the branding files are
/// currently inputs to `flutter_launcher_icons` and are not bundled, so
/// an `Image.asset` here would silently 404 until someone remembered
/// the manifest); no SVG dependency; and it is resolution-free, which
/// matters because this appears at 20px in an app bar and could appear
/// much larger on a landing surface.
///
/// The arc maths is kept in one place deliberately. Two arcs that are
/// each half-right meet in a visible seam, and that is the kind of
/// defect nobody files.
class NduzemMark extends StatelessWidget {
  const NduzemMark({super.key, this.size = 24, this.semanticLabel});

  final double size;

  /// Null by default, which is right wherever the word "Nduzem" sits
  /// next to the mark — announcing it twice is worse than not at all.
  final String? semanticLabel;

  /// Deep Purple 500 — matches `seedColor` in `app.dart` and the
  /// `#673AB7` in logo.svg.
  static const Color primary = Color(0xFF673AB7);

  /// Deep Purple 100 — `#D1C4E9` in logo.svg.
  static const Color secondary = Color(0xFFD1C4E9);

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: const _MarkPainter()),
    );
    final label = semanticLabel;
    if (label == null) return ExcludeSemantics(child: mark);
    return Semantics(label: label, image: true, child: mark);
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  // Fractions of the 512-unit viewBox in logo.svg, so the two cannot
  // drift: centreline radius 185/512, stroke width 110/512.
  static const double _radiusFraction = 185 / 512;
  static const double _strokeFraction = 110 / 512;

  @override
  void paint(Canvas canvas, Size size) {
    final box = math.min(size.width, size.height);
    final centre = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: centre, radius: box * _radiusFraction);

    // Butt caps so the two halves meet flush along the diagonal, as in
    // the SVG. Round caps overshoot and the seam shows as a notch.
    Paint stroke(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = box * _strokeFraction
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;

    // Flutter's sweep is clockwise from 3 o'clock with y down, the same
    // convention as the SVG's screen coordinates, so the angles carry
    // over unchanged: the diagonal endpoints are at 45 degrees (SE) and
    // 225 degrees (NW).
    //
    // Top-right half: 225 degrees sweeping through 270 (top) and 0
    // (right) to 45.
    canvas.drawArc(
      rect,
      5 * math.pi / 4,
      math.pi,
      false,
      stroke(NduzemMark.primary),
    );
    // Bottom-left half: 45 degrees through 90 (bottom) and 180 (left).
    canvas.drawArc(
      rect,
      math.pi / 4,
      math.pi,
      false,
      stroke(NduzemMark.secondary),
    );
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}

/// Mark plus the word, for an app bar title or a page header.
///
/// Exists because the public pages are the only places a stranger meets
/// this product, and on those the brand has to be the thing that
/// identifies the page. The mark alone is not recognisable yet.
class NduzemWordmark extends StatelessWidget {
  const NduzemWordmark({super.key, this.markSize = 22, this.style});

  final double markSize;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          NduzemMark(size: markSize),
          const SizedBox(width: 8),
          Text(
            'Nduzem',
            style: style ?? Theme.of(context).textTheme.titleLarge,
          ),
        ],
      ),
    );
  }
}
