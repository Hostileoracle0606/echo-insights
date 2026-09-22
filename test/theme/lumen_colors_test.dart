import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/theme/lumen_colors.dart';

void main() {
  test('light palette has the exact OKLCH-derived hex values', () {
    expect(LumenColors.light.paper, const Color(0xFFF9F5EC));
    expect(LumenColors.light.ink, const Color(0xFF17100C));
    expect(LumenColors.light.amber, const Color(0xFFEB881F));
    expect(LumenColors.light.sage, const Color(0xFF527D65));
    expect(LumenColors.light.destructive, const Color(0xFFCC272E));
  });

  test('entityColors covers every EntityType', () {
    // entityColors is `static const` (it has no light/dark variant, so it
    // isn't part of the instance), so it's read off the class, not an
    // instance: LumenColors.entityColors, not LumenColors.light.entityColors.
    for (final type in EntityType.values) {
      expect(
        LumenColors.entityColors[type],
        isNotNull,
        reason: 'missing color for $type',
      );
    }
    expect(
      LumenColors.entityColors[EntityType.person],
      const Color(0xFFC97B3A),
    );
  });

  test('copyWith overrides one field and leaves the rest', () {
    final c = LumenColors.light.copyWith(amber: const Color(0xFF000000));
    expect(c.amber, const Color(0xFF000000));
    expect(c.paper, LumenColors.light.paper);
  });

  test('lerp(self, self, 0.5) returns equal values', () {
    final l = LumenColors.light.lerp(LumenColors.light, 0.5);
    expect(l.paper, LumenColors.light.paper);
    expect(l.ink, LumenColors.light.ink);
  });
}
