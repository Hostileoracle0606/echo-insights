import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';

void main() {
  final theme = LumenTheme.light();

  test('scaffold + key ColorScheme roles map to Lumen tokens', () {
    expect(theme.scaffoldBackgroundColor, LumenColors.light.paper);
    expect(theme.colorScheme.primary, LumenColors.light.ink);
    expect(theme.colorScheme.onPrimary, LumenColors.light.paper);
    expect(theme.colorScheme.secondary, LumenColors.light.sage);
    expect(theme.colorScheme.tertiary, LumenColors.light.amber);
    expect(theme.colorScheme.surface, LumenColors.light.paper);
    expect(theme.colorScheme.error, LumenColors.light.destructive);
    expect(theme.colorScheme.brightness, Brightness.light);
  });

  test('both extensions are registered', () {
    expect(theme.extension<LumenColors>(), LumenColors.light);
    expect(theme.extension<LumenSurface>(), isNotNull);
  });

  test('LumenSurface exposes the radius scale and warm shadows', () {
    final s = theme.extension<LumenSurface>()!;
    expect(s.radiusSm, 4);
    expect(s.radiusLg, 8);
    expect(s.radius2xl, 16);
    expect(s.shadowPaper.length, 2);
    expect(s.shadowInk.length, 1);
  });

  test('textTheme is wired with Fraunces display', () {
    expect(theme.textTheme.displayLarge!.fontFamily, 'Fraunces');
  });
}
