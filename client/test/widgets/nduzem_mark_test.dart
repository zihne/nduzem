// The mark is drawn from arc maths rather than loaded from the SVG, so
// the one thing that can be silently wrong is orientation: swap the two
// `drawArc` calls, or get Flutter's sweep direction backwards, and the
// code still compiles, still paints a ring, and ships a brand mark that
// is the mirror image of the app icon and the favicon.
//
// So these sample actual pixels. Angle conventions are exactly the kind
// of thing that is easy to reason about confidently and wrongly.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nduzem/widgets/nduzem_mark.dart';

const int _px = 240;
const double _size = 240;

/// Paints the mark on white and returns its pixels.
///
/// The capture goes through `tester.runAsync`. `toImage()` and
/// `toByteData()` wait on real work from the engine, and a widget test
/// drives a fake clock, so awaiting them directly does not time out —
/// it hangs for ever.
Future<ByteData> _renderPixels(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      home: ColoredBox(
        color: Colors.white,
        child: Center(
          child: RepaintBoundary(child: NduzemMark(size: _size)),
        ),
      ),
    ),
  );
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).last,
  );
  final pixels = await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage();
    try {
      return await image.toByteData();
    } finally {
      image.dispose();
    }
  });
  return pixels!;
}

// `_px` is declared beside `_size` above: the captured bitmap is square
// and `_size` logical pixels wide at the test's 1.0 device pixel ratio.

/// One pixel, as the four bytes the engine actually wrote. Deliberately
/// not a `Color`: its channel getters are deprecated in favour of
/// floating-point ones, and comparing bytes to bytes avoids both the
/// deprecation and a rounding round-trip.
class _Px {
  const _Px(this.r, this.g, this.b, this.a);
  final int r;
  final int g;
  final int b;
  final int a;

  @override
  String toString() => 'rgba($r, $g, $b, $a)';
}

_Px _at(ByteData pixels, double fx, double fy) {
  final x = (_px * fx).round().clamp(0, _px - 1);
  final y = (_px * fy).round().clamp(0, _px - 1);
  final offset = (y * _px + x) * 4;
  return _Px(
    pixels.getUint8(offset),
    pixels.getUint8(offset + 1),
    pixels.getUint8(offset + 2),
    pixels.getUint8(offset + 3),
  );
}

// The two brand colours as bytes: #673AB7 and #D1C4E9, the same values
// as in logo.svg and NduzemMark.
const _Px _solid = _Px(0x67, 0x3A, 0xB7, 0xFF);
const _Px _pale = _Px(0xD1, 0xC4, 0xE9, 0xFF);

/// Channel-wise closeness. Antialiasing means an exact match is only
/// reliable well inside a stroke, and the ring is thick enough that the
/// midpoints sampled below are.
void _expectNear(_Px got, _Px want, {int tolerance = 12}) {
  final close = (got.r - want.r).abs() <= tolerance &&
      (got.g - want.g).abs() <= tolerance &&
      (got.b - want.b).abs() <= tolerance &&
      (got.a - want.a).abs() <= tolerance;
  expect(close, isTrue, reason: 'expected ~$want, got $got');
}

void main() {
  testWidgets('the ring is split with the dark half top-right',
      (tester) async {
    final pixels = await _renderPixels(tester);

    // The stroke centreline sits at 185/512 of the box from the centre,
    // i.e. 0.3613 either side of 0.5 -> 0.139 and 0.861.
    const near = 0.139;
    const far = 0.861;

    // Top of the ring and the right of the ring are the solid half.
    _expectNear(_at(pixels, 0.5, near), _solid);
    _expectNear(_at(pixels, far, 0.5), _solid);

    // Bottom and left are the light half.
    _expectNear(_at(pixels, 0.5, far), _pale);
    _expectNear(_at(pixels, near, 0.5), _pale);
  });

  testWidgets('the centre is open, so it reads as a ring not a disc',
      (tester) async {
    final pixels = await _renderPixels(tester);
    // Fully transparent rather than white: the hole is unpainted, so
    // the mark composites over whatever is behind it. That matters
    // because it sits on an app bar on one surface and on an off-white
    // card on another, and a filled white centre would show as a disc
    // on the first.
    expect(_at(pixels, 0.5, 0.5).a, 0);
    // And the arcs themselves are opaque, so "transparent centre" is
    // not just a capture that came back empty.
    expect(_at(pixels, 0.5, 0.139).a, 255);
  });

  testWidgets('the wordmark shows the name beside the mark', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NduzemWordmark())),
    );
    expect(find.text('Nduzem'), findsOneWidget);
    expect(find.byType(NduzemMark), findsOneWidget);
  });
}
