// Generates Lumen's interim iOS app icon set and launch-screen mark.
//
//   dart run tool/generate_app_icons.dart
//
// Placeholder artwork, not a brand: a geometric "aperture" (an amber disc
// inside an open ink ring) on the paper ground, using the exact tokens from
// `LumenColors.light` in lib/theme/lumen_colors.dart. Every PNG size is derived
// from AppIcon.appiconset/Contents.json, so the set stays reproducible.
//
// Constraints App Store Connect enforces, and this script honours:
//   * no alpha channel -- PNGs are written as colortype 2 (8-bit RGB)
//   * no text in the mark
//
// Uses only dart:io so it runs without adding packages to pubspec.yaml.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// LumenColors.light
const _paper = [0xF9, 0xF5, 0xEC];
const _amber = [0xEB, 0x88, 0x1F];
const _ink = [0x17, 0x10, 0x0C];

// Mark geometry in unit space (0..1), y down.
const _discRadius = 0.20;
const _ringRadius = 0.33;
const _ringWidth = 0.055;
// The ring opens toward the upper right; the gap spans 70 degrees.
const _gapCentreDeg = -45.0;
const _gapDeg = 70.0;

const _iconDir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
const _launchDir = 'ios/Runner/Assets.xcassets/LaunchMark.imageset';

void main() {
  final contents = jsonDecode(File('$_iconDir/Contents.json').readAsStringSync())
      as Map<String, dynamic>;
  final written = <String>{};
  for (final image in (contents['images'] as List).cast<Map<String, dynamic>>()) {
    final filename = image['filename'] as String;
    final points = double.parse((image['size'] as String).split('x').first);
    final scale = int.parse((image['scale'] as String).replaceAll('x', ''));
    final px = (points * scale).round();
    if (!written.add(filename)) continue; // shared by iphone and ipad idioms
    File('$_iconDir/$filename').writeAsBytesSync(_encodePng(px, _renderIcon(px)));
    stdout.writeln('$filename  ${px}x$px');
  }

  Directory(_launchDir).createSync(recursive: true);
  File('$_launchDir/LaunchMark.svg').writeAsStringSync(_launchSvg());
  File('$_launchDir/Contents.json').writeAsStringSync(_launchContents);
  stdout.writeln('LaunchMark.svg');
}

double get _arcStartDeg => _gapCentreDeg + _gapDeg / 2;
double get _arcSpanDeg => 360 - _gapDeg;

/// 0 = ground, 1 = amber disc, 2 = ink ring.
int _sample(double x, double y) {
  final dx = x - 0.5, dy = y - 0.5;
  final r = math.sqrt(dx * dx + dy * dy);
  if (_inRing(dx, dy, r)) return 2;
  if (r <= _discRadius) return 1;
  return 0;
}

bool _inRing(double dx, double dy, double r) {
  const half = _ringWidth / 2;
  var rel = math.atan2(dy, dx) * 180 / math.pi - _arcStartDeg;
  rel = ((rel % 360) + 360) % 360;
  if (rel <= _arcSpanDeg) return (r - _ringRadius).abs() <= half;
  // Round caps at both ends.
  for (final deg in [_arcStartDeg, _arcStartDeg + _arcSpanDeg]) {
    final a = deg * math.pi / 180;
    final ex = dx - _ringRadius * math.cos(a), ey = dy - _ringRadius * math.sin(a);
    if (ex * ex + ey * ey <= half * half) return true;
  }
  return false;
}

Uint8List _renderIcon(int px) {
  // Supersample for anti-aliasing; small sizes get more samples per pixel.
  final ss = px >= 512 ? 4 : 8;
  final out = Uint8List(px * px * 3);
  const palette = [_paper, _amber, _ink];
  for (var py = 0; py < px; py++) {
    for (var pxX = 0; pxX < px; pxX++) {
      final acc = [0, 0, 0];
      for (var sy = 0; sy < ss; sy++) {
        for (var sx = 0; sx < ss; sx++) {
          final c = palette[_sample((pxX + (sx + 0.5) / ss) / px, (py + (sy + 0.5) / ss) / px)];
          acc[0] += c[0];
          acc[1] += c[1];
          acc[2] += c[2];
        }
      }
      final o = (py * px + pxX) * 3;
      for (var i = 0; i < 3; i++) {
        out[o + i] = (acc[i] / (ss * ss)).round();
      }
    }
  }
  return out;
}

Uint8List _encodePng(int size, Uint8List rgb) {
  final raw = BytesBuilder();
  for (var y = 0; y < size; y++) {
    raw.addByte(0); // filter: none
    raw.add(Uint8List.sublistView(rgb, y * size * 3, (y + 1) * size * 3));
  }
  final ihdr = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2) // colortype 2: RGB, no alpha
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  return (BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(_chunk('IHDR', ihdr.buffer.asUint8List()))
        ..add(_chunk('IDAT', ZLibEncoder(level: 9).convert(raw.takeBytes())))
        ..add(_chunk('IEND', const [])))
      .takeBytes();
}

List<int> _chunk(String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final len = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32([...typeBytes, ...data]));
  return [...len.buffer.asUint8List(), ...typeBytes, ...data, ...crc.buffer.asUint8List()];
}

final List<int> _crcTable = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

String _hex(List<int> c) => '#${c.map((v) => v.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';

/// The same mark as a vector, without the ground, for LaunchScreen.storyboard
/// (whose background is set to paper directly).
String _launchSvg() {
  String pt(double deg) {
    final a = deg * math.pi / 180;
    final x = 50 + _ringRadius * 100 * math.cos(a), y = 50 + _ringRadius * 100 * math.sin(a);
    return '${x.toStringAsFixed(3)} ${y.toStringAsFixed(3)}';
  }

  final r = (_ringRadius * 100).toStringAsFixed(3);
  return '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="160" viewBox="0 0 100 100">\n'
      '  <circle cx="50" cy="50" r="${(_discRadius * 100).toStringAsFixed(3)}" fill="${_hex(_amber)}"/>\n'
      '  <path d="M ${pt(_arcStartDeg)} A $r $r 0 1 1 ${pt(_arcStartDeg + _arcSpanDeg)}" '
      'fill="none" stroke="${_hex(_ink)}" stroke-width="${(_ringWidth * 100).toStringAsFixed(3)}" '
      'stroke-linecap="round"/>\n'
      '</svg>\n';
}

const _launchContents = '''{
  "images" : [
    {
      "filename" : "LaunchMark.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true
  }
}
''';
