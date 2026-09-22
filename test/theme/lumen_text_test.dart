import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_text.dart';

void main() {
  final tt = LumenText.textTheme(
    foreground: const Color(0xFF17100C),
    mutedForeground: const Color(0xFF564B42),
  );

  test('all 15 text slots are defined', () {
    final slots = <TextStyle?>[
      tt.displayLarge,
      tt.displayMedium,
      tt.displaySmall,
      tt.headlineLarge,
      tt.headlineMedium,
      tt.headlineSmall,
      tt.titleLarge,
      tt.titleMedium,
      tt.titleSmall,
      tt.bodyLarge,
      tt.bodyMedium,
      tt.bodySmall,
      tt.labelLarge,
      tt.labelMedium,
      tt.labelSmall,
    ];
    expect(slots.where((s) => s == null), isEmpty);
  });

  test('display/headline/titleLarge use Fraunces; body/label use Inter', () {
    expect(tt.displayLarge!.fontFamily, 'Fraunces');
    expect(tt.headlineMedium!.fontFamily, 'Fraunces');
    expect(tt.titleLarge!.fontFamily, 'Fraunces');
    expect(tt.titleMedium!.fontFamily, 'Inter');
    expect(tt.bodyMedium!.fontFamily, 'Inter');
    expect(tt.labelSmall!.fontFamily, 'Inter');
  });

  test('Fraunces styles apply ss01 only and explicit variable axes', () {
    expect(tt.displayLarge!.fontFeatures, [FontFeature.stylisticSet(1)]);
    final vars = tt.displayLarge!.fontVariations!;
    expect(vars, contains(const FontVariation('wght', 400)));
    expect(vars, contains(const FontVariation('opsz', 40))); // opsz tracks size
    expect(vars, contains(const FontVariation('WONK', 0)));
    expect(vars, contains(const FontVariation('SOFT', 0)));
  });

  test('eyebrow is semibold, wide-tracked, 10px', () {
    final e = LumenText.eyebrow(const Color(0xFF564B42));
    expect(e.fontFamily, 'Inter');
    expect(e.fontSize, 10);
    expect(e.fontWeight, FontWeight.w600);
    expect(e.letterSpacing, 1.4);
  });
}
