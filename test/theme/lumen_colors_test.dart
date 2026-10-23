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

  group('LM-09 card tokens', () {
    const expected = <String, Color>{
      'highlight': Color(0xFFFBF1E4),
      'sageSoft': Color(0xFFDCE7DF),
      'sageInk': Color(0xFF2F4D3D),
      'lumenLabel': Color(0xFF3F6550),
      'youLabel': Color(0xFF8A4A0C),
      'lumenBody': Color(0xFF3A2A1E),
    };

    // One accessor per new token, so a token missing from copyWith or lerp
    // fails by name instead of silently keeping the old colour.
    final read = <String, Color Function(LumenColors)>{
      'highlight': (c) => c.highlight,
      'sageSoft': (c) => c.sageSoft,
      'sageInk': (c) => c.sageInk,
      'lumenLabel': (c) => c.lumenLabel,
      'youLabel': (c) => c.youLabel,
      'lumenBody': (c) => c.lumenBody,
    };

    LumenColors withToken(String name, Color color) => switch (name) {
          'highlight' => LumenColors.light.copyWith(highlight: color),
          'sageSoft' => LumenColors.light.copyWith(sageSoft: color),
          'sageInk' => LumenColors.light.copyWith(sageInk: color),
          'lumenLabel' => LumenColors.light.copyWith(lumenLabel: color),
          'youLabel' => LumenColors.light.copyWith(youLabel: color),
          'lumenBody' => LumenColors.light.copyWith(lumenBody: color),
          _ => throw ArgumentError(name),
        };

    test('have the exact hex values', () {
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(read[key]!(LumenColors.light), value, reason: key);
      }
    });

    test('copyWith sets each one and keeps the others', () {
      const probe = Color(0xFF010203);
      for (final name in expected.keys) {
        final c = withToken(name, probe);
        expect(read[name]!(c), probe, reason: name);
        for (final other in expected.keys.where((n) => n != name)) {
          expect(read[other]!(c), expected[other], reason: '$name -> $other');
        }
      }
    });

    test('lerp carries each one through', () {
      const probe = Color(0xFF010203);
      for (final name in expected.keys) {
        final target = withToken(name, probe);
        expect(read[name]!(LumenColors.light.lerp(target, 0)), expected[name],
            reason: '$name at t=0');
        expect(read[name]!(LumenColors.light.lerp(target, 1)), probe,
            reason: '$name at t=1');
      }
    });

    test('role aliases point at the ring colours', () {
      expect(LumenColors.light.recallRing, LumenColors.light.sage);
      expect(LumenColors.light.upsertRing, LumenColors.light.amber);
    });
  });
}
