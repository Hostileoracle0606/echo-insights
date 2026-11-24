/// EC-07: correct_memory's spoken arguments as the typed change the database
/// proposes ("7k" is 7000, "planned" is status proposed). Null when nothing
/// would change.
Map<String, dynamic>? correctionChange(Map<String, dynamic> args) {
  final change = <String, dynamic>{};
  if (args['remove'] == true) return {'remove': true};

  final value = args['value'];
  if (value is num) {
    change['valueNum'] = value;
  } else if (value is String && value.trim().isNotEmpty) {
    final parsed = _number(value.trim());
    if (parsed != null) {
      change['valueNum'] = parsed;
    } else {
      change['valueText'] = value.trim();
    }
  }
  final unit = args['unit'];
  if (unit is String && unit.trim().isNotEmpty) change['unit'] = unit.trim();

  final date = args['date'];
  if (date is String && date.trim().isNotEmpty) {
    final d = date.trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d) || DateTime.tryParse(d) == null) {
      return null;
    }
    change['eventAt'] = '${d}T12:00:00Z';
  }

  final status = args['status'];
  if (status is String && status.trim().isNotEmpty) {
    final mapped = switch (status.trim().toLowerCase()) {
      'done' || 'confirmed' || 'happened' => 'confirmed',
      'planned' || 'proposed' || 'plan' => 'proposed',
      'called off' || 'cancelled' || 'canceled' => 'cancelled',
      _ => null,
    };
    if (mapped == null) return null;
    change['status'] = mapped;
  }

  final owner = args['belongs_to'];
  if (owner is String && owner.trim().isNotEmpty) change['entity'] = owner.trim();

  final changes = change.keys.where((k) => k != 'unit');
  return changes.isEmpty ? null : change;
}

/// "7k" → 7000, "7,000" → 7000, "12.5" → 12.5; null when not a number.
num? _number(String text) {
  final m = RegExp(r'^\$?\s*([\d,]+(?:\.\d+)?)\s*(k|thousand|m|million)?$', caseSensitive: false)
      .firstMatch(text);
  if (m == null) return null;
  final base = num.tryParse(m.group(1)!.replaceAll(',', ''));
  if (base == null) return null;
  final scale = switch (m.group(2)?.toLowerCase()) {
    'k' || 'thousand' => 1000,
    'm' || 'million' => 1000000,
    _ => 1,
  };
  final result = base * scale;
  return result == result.roundToDouble() ? result.toInt() : result;
}
