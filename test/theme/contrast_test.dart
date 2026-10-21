// WCAG 2.x contrast for the LM-09 text tokens: every small-text pairing in the
// token table must reach 4.5:1 (AA, normal text). sage and amber are recorded
// as the reason the label tokens exist — fine for rings and dots, not text.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_colors.dart';

double _channel(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

double contrastRatio(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  const c = LumenColors.light;

  test('contrastRatio matches known WCAG values', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(contrastRatio(Colors.white, Colors.white), closeTo(1, 0.001));
  });

  final pairs = <String, (Color, Color, double)>{
    'ink on highlight': (c.ink, c.highlight, 16.85),
    'sageInk on sageSoft': (c.sageInk, c.sageSoft, 7.35),
    'lumenLabel on paper': (c.lumenLabel, c.paper, 6.05),
    'youLabel on highlight': (c.youLabel, c.highlight, 6.13),
    'youLabel on paper': (c.youLabel, c.paper, 6.30),
    'lumenBody on paper': (c.lumenBody, c.paper, 12.62),
    // Labels also land on the raised card.
    'lumenLabel on card': (c.lumenLabel, c.card, 6.38),
    'youLabel on card': (c.youLabel, c.card, 6.64),
    'mutedForeground on card': (c.mutedForeground, c.card, 8.20),
    'mutedForeground on muted': (c.mutedForeground, c.muted, 6.88),
    'mutedForeground on highlight': (c.mutedForeground, c.highlight, 7.58),
    'mutedForeground on sageSoft': (c.mutedForeground, c.sageSoft, 6.67),
  };

  for (final MapEntry(key: name, value: (fg, bg, measured)) in pairs.entries) {
    test('$name reaches 4.5:1 (measured $measured)', () {
      final ratio = contrastRatio(fg, bg);
      expect(ratio, greaterThanOrEqualTo(4.5));
      expect(ratio, closeTo(measured, 0.01));
    });
  }

  test('sage and amber stay below text contrast (rings and fills only)', () {
    expect(contrastRatio(c.sage, c.paper), closeTo(4.31, 0.01));
    expect(contrastRatio(c.amber, c.paper), closeTo(2.39, 0.01));
  });
}
