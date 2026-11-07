// On-device name swap (LM-55): the map between the real names in a user's
// journal and the consistent fake names a model sees instead.
//
// The spike (docs/superpowers/specs/2026-11-07-pseudonymization-spike.md)
// found only fake names, not tags, kept extraction quality, so a real name
// always becomes the same invented name of the same kind: a person gets a
// person's name, a town a town's, an employer an employer's. The strategy
// sits behind [SurrogateStrategy] and the map's public surface is
// dehydrate / rehydrate, so it could change without touching callers.
//
// Pure Dart, no Flutter imports. The map holds real names: it lives only on
// the device (see PseudonymService), never in a log, a request or an error.

import '../../models/entity.dart';
import '../slugify.dart';
import 'common_words.dart';
import 'fake_names.dart';
import 'fuzzy.dart';
import 'gender_hints.dart';
import 'latin_decompositions.dart';
import 'name_recognizer.dart';
import 'public_entities.dart';
import 'word_context.dart';

/// One entity of the user's graph, as the swap needs it.
class PseudonymEntity {
  const PseudonymEntity({
    required this.id,
    required this.name,
    required this.kind,
    this.aliases = const [],
    this.gender,
  });

  final String id;
  final String name;
  final PseudonymKind kind;
  final List<String> aliases;
  final Gender? gender;

  /// The swap's view of a graph [entity], or null when the entity is not a
  /// private identifier (a public place, a company everyone knows, an
  /// activity, an emotion...): those are kept as they are. Aliases come from
  /// `metadata['aliases']` when the graph has them.
  static PseudonymEntity? fromEntity(Entity entity) {
    final kind = pseudonymKindFor(entity.type);
    if (kind == null || !isPrivateIdentifier(kind, entity.name)) return null;
    final raw = entity.metadata['aliases'];
    final aliases = raw is List ? raw.whereType<String>().toList() : <String>[];
    return PseudonymEntity(
      id: entity.id,
      name: entity.name,
      kind: kind,
      aliases: aliases,
      gender: kind == PseudonymKind.person
          ? inferGender(
              name: entity.name,
              aliases: aliases,
              description: entity.description,
              role: entity.metadata['role'] as String?,
              explicit: entity.metadata['gender'] as String?,
            )
          : null,
    );
  }
}

/// What the map keeps for one real name. Mutable only through the map.
class PseudonymEntry {
  PseudonymEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.fake,
    List<String>? aliases,
    this.gender,
    this.surname,
    this.learned = false,
    Map<String, String>? fakes,
  })  : aliases = aliases ?? [],
        fakes = fakes ?? {};

  final String id;
  String name;
  final PseudonymKind kind;
  final List<String> aliases;
  final Gender? gender;

  /// The stand-in for [name]. Replaced only when a real name in the graph
  /// turns out to equal it.
  String fake;

  /// A second name for the stand-in, used when an alias adds one to [name].
  String? surname;

  /// Found by name recognition, not (yet) a graph entity.
  bool learned;

  /// Stand-in for each surface form (name and aliases).
  final Map<String, String> fakes;

  List<String> get surfaces => [name, ...aliases];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'aliases': aliases,
        if (gender != null) 'gender': gender!.name,
        'fake': fake,
        if (surname != null) 'surname': surname,
        if (learned) 'learned': true,
        'fakes': fakes,
      };

  factory PseudonymEntry.fromJson(Map<String, dynamic> json) => PseudonymEntry(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: PseudonymKind.values.byName(json['kind'] as String),
        fake: json['fake'] as String,
        aliases: (json['aliases'] as List).cast<String>().toList(),
        gender: json['gender'] == null
            ? null
            : Gender.values.byName(json['gender'] as String),
        surname: json['surname'] as String?,
        learned: json['learned'] == true,
        fakes: (json['fakes'] as Map).cast<String, String>(),
      );
}

/// One replacement made by [PseudonymMap.dehydrate].
class Replacement {
  const Replacement({
    required this.start,
    required this.end,
    required this.outStart,
    required this.original,
    required this.replacement,
    required this.entityId,
    required this.fuzzy,
  });

  /// Where [original] sat in the input, and where [replacement] sits in the
  /// output.
  final int start;
  final int end;
  final int outStart;
  final String original;
  final String replacement;
  final String entityId;

  /// Matched by spelling or sound, not exactly.
  final bool fuzzy;
}

/// The result of [PseudonymMap.dehydrate].
class Dehydrated {
  Dehydrated({
    required this.original,
    required this.text,
    required this.replacements,
    required this.mapChanged,
  });

  final String original;

  /// [original] with every known name replaced: what a model may see.
  final String text;
  final List<Replacement> replacements;

  /// The map learned something while swapping (a name that collided with a
  /// stand-in), so it should be saved before the text is sent.
  final bool mapChanged;

  /// Puts back exactly what [dehydrate] replaced. Valid only for [text]
  /// itself, byte for byte: any other string (shifted, edited, extended)
  /// returns null, because the replacements are located by offset and a
  /// search would put an original in the wrong place. To turn a model's
  /// output back into names, use [PseudonymMap.rehydrateModelOutput].
  String? restore([String? swapped]) {
    if (swapped != null && swapped != text) return null;
    final out = StringBuffer();
    var cursor = 0;
    for (final r in replacements) {
      if (r.outStart < cursor || !text.startsWith(r.replacement, r.outStart)) {
        return null;
      }
      out
        ..write(text.substring(cursor, r.outStart))
        ..write(r.original);
      cursor = r.outStart + r.replacement.length;
    }
    out.write(text.substring(cursor));
    return out.toString();
  }

  /// True when swapping back restores the input exactly. Checked by
  /// [PseudonymMap.dehydrate]; false would be a bug, and the caller should
  /// not send [text].
  bool get roundTripOk => restore() == original;
}

class _Surface {
  _Surface(this.form, this.entry, this.regex, this.word);
  final String form;
  final PseudonymEntry entry;
  final RegExp regex;
  final bool word;
}

class _Match {
  _Match(this.start, this.end, this.entry, this.surface, this.original,
      {this.fuzzy = false});
  final int start;
  final int end;
  final PseudonymEntry entry;
  final String surface;
  final String original;
  final bool fuzzy;
}

const _latinOnly = r'[\p{Script=Latin}\p{M}\s\u0027\u2019.\-]+';
final _latinRe = RegExp('^$_latinOnly\$', unicode: true);
bool _isLatin(String s) => _latinRe.hasMatch(s);

/// A regex for [form] that treats spaces and hyphens inside it as
/// interchangeable ("Jean-Luc" matches "Jean Luc") and accepts an accented
/// letter either precomposed or as letter + combining mark.
String _pattern(String form) {
  final parts = composeLatin(form.trim()).split(RegExp(r'[\s-]+'));
  return parts.map((part) {
    final b = StringBuffer();
    for (final ch in part.runes.map(String.fromCharCode)) {
      final d = latinDecompositions[ch];
      b.write(d == null
          ? RegExp.escape(ch)
          : '(?:${RegExp.escape(ch)}|${RegExp.escape(d)})');
    }
    return b.toString();
  }).join(r'[\s\-]+');
}

// Around Latin text: no Latin letter, digit, underscore or combining mark
// touching it. Other scripts have no spaces to rely on (김민수는, Ивана), so
// they get none.
const _before = r'(?<![\p{Script=Latin}\p{N}_\p{M}])';
const _after = r'(?![\p{Script=Latin}\p{N}_\p{M}])';
// A stand-in glued to another word by a hyphen is not a stand-in
// ("Giselle-Rose").
const _backBefore = '$_before(?<!\\p{L}-)';
const _backAfter = '$_after(?!-\\p{L})';

class PseudonymMap {
  PseudonymMap({
    SurrogateStrategy strategy = const FakeNameStrategy(),
    this.ownerId,
  }) : _strategy = strategy;

  factory PseudonymMap.fromJson(
    Map<String, dynamic> json, {
    SurrogateStrategy strategy = const FakeNameStrategy(),
  }) {
    if (json['v'] != 1) throw const FormatException('pseudonym map version');
    final map = PseudonymMap(
      strategy: strategy,
      ownerId: json['owner'] as String?,
    );
    for (final e in (json['entries'] as List).cast<Map<String, dynamic>>()) {
      final entry = PseudonymEntry.fromJson(e);
      map._entries[entry.id] = entry;
    }
    map._retired.addAll((json['retired'] as List).cast<String>());
    map._reserved.addAll(((json['reserved'] as List?) ?? const []).cast<String>());
    return map;
  }

  final SurrogateStrategy _strategy;

  /// The signed-in user this map belongs to; a map for someone else is dropped.
  final String? ownerId;

  final Map<String, PseudonymEntry> _entries = {};

  /// Lowercase stand-in tokens of forgotten entities: never issued again, so
  /// a forgotten person's stand-in cannot come to mean someone else while
  /// older results that mention it still exist. Holds no real name.
  final Set<String> _retired = {};

  /// Lowercase tokens of every name in the user's graph, public ones too, so
  /// a stand-in can never be a real name there. Added to by [sync] and saved
  /// with the map (these are real names: the map never leaves the device).
  final Set<String> _reserved = {};

  List<_Surface>? _surfaceIndex;
  RegExp? _backRegex;

  /// Spellings the user used for each stand-in since the last [sync]
  /// (stand-in -> spellings), so model output can say "Sam" when only "Sam"
  /// was ever sent. Memory only.
  final Map<String, Set<String>> _spellings = {};
  Map<String, ({PseudonymEntry entry, String surface})>? _back;

  bool get isEmpty => _entries.isEmpty;
  Iterable<String> get entityIds => _entries.keys;
  bool contains(String entityId) => _entries.containsKey(entityId);

  Map<String, dynamic> toJson() => {
        'v': 1,
        if (ownerId != null) 'owner': ownerId,
        'entries': [for (final e in _entries.values) e.toJson()],
        'retired': _retired.toList()..sort(),
        'reserved': _reserved.toList()..sort(),
      };

  // --- building the map ---------------------------------------------------

  /// Brings the map up to date with the user's graph: new private entities
  /// get a stand-in, known ones pick up renamed names and new aliases, and
  /// [suppressed] ids (removed or forgotten) are dropped and never added.
  /// Entities missing from [entities] are kept: the graph slice a call
  /// carries is not the whole graph. [allNames] are every graph name,
  /// public ones included, kept out of the stand-in pool. True if the map
  /// changed.
  bool sync(
    Iterable<PseudonymEntity> entities, {
    Iterable<String> allNames = const [],
    Set<String> suppressed = const {},
  }) {
    var changed = false;
    for (final name in allNames) {
      _reserved.addAll(_tokens(name));
    }
    for (final id in suppressed) {
      changed |= forget(id);
    }
    for (final e in entities) {
      if (e.name.trim().isEmpty || suppressed.contains(e.id)) continue;
      _reserved
        ..addAll(_tokens(e.name))
        ..addAll(e.aliases.expand(_tokens));
    }
    for (final e in entities) {
      if (e.name.trim().isEmpty || suppressed.contains(e.id)) continue;
      var entry = _entries[e.id] ?? _adoptByName(e);
      if (entry == null) {
        entry = _create(e.id, e.name, e.kind, e.aliases, e.gender);
        changed = true;
      } else {
        changed |= _update(entry, e);
      }
    }
    _spellings.clear();
    if (changed) _invalidate();
    changed |= _reissueCollisions();
    return changed;
  }

  /// Adds names the recognizer found that the graph does not know yet.
  /// People, places and organisations only; names that are ordinary words
  /// (a recognizer calling "Will" a person) and public identifiers are not
  /// learned. True if the map changed.
  bool learn(Iterable<RecognizedName> names) {
    var changed = false;
    for (final n in names) {
      final text = n.text.trim();
      if (text.length < 2) continue;
      if (isWordName(text) || !isPrivateIdentifier(n.kind, text)) continue;
      if (_isStandIn(text)) continue;
      // Already known, by spelling or sound: "Pria" is Priya, not someone new.
      // A known first name with more after it ("Samantha Lee") is the same
      // person under a longer name: keep the one stand-in and add the alias.
      final known = dehydrate(text).replacements;
      if (known.isNotEmpty) {
        final first = known.first;
        if (n.kind == PseudonymKind.person &&
            known.length == 1 &&
            first.start == 0 &&
            first.end < text.length) {
          changed |= _addAliases(_entries[first.entityId]!, [text]);
        }
        continue;
      }
      final id = slugify(text);
      if (_entries.containsKey(id)) continue;
      _create(id, text, n.kind, const [], null, learned: true);
      changed = true;
    }
    if (changed) _invalidate();
    changed |= _reissueCollisions();
    return changed;
  }

  /// Removes [entityId] and everything derived from it: its real name, its
  /// aliases and its stand-ins. The stand-ins are retired, not reused.
  bool forget(String entityId) {
    final entry = _entries.remove(entityId);
    if (entry == null) return false;
    for (final fake in entry.fakes.values) {
      _retired.addAll(_tokens(fake));
    }
    _retired.addAll(_tokens(entry.fake));
    _invalidate();
    return true;
  }

  PseudonymEntry? _adoptByName(PseudonymEntity e) {
    // A name found by recognition that the graph now has under its own id.
    for (final entry in _entries.values.toList()) {
      if (entry.learned && entry.name.toLowerCase() == e.name.toLowerCase()) {
        _entries.remove(entry.id);
        final adopted = PseudonymEntry(
          id: e.id,
          name: entry.name,
          kind: entry.kind,
          fake: entry.fake,
          aliases: entry.aliases,
          gender: entry.gender ?? e.gender,
          surname: entry.surname,
          fakes: entry.fakes,
        );
        _entries[e.id] = adopted;
        return adopted;
      }
    }
    return null;
  }

  PseudonymEntry _create(
    String id,
    String name,
    PseudonymKind kind,
    List<String> aliases,
    Gender? gender, {
    bool learned = false,
  }) {
    final fake = _strategy.next(
      kind: kind,
      seed: _seed(id),
      gender: gender,
      isTaken: (c) => _isTaken(c, kind),
    );
    final entry = PseudonymEntry(
      id: id,
      name: name,
      kind: kind,
      fake: fake,
      gender: gender,
      learned: learned,
    )..fakes[name] = fake;
    _entries[id] = entry;
    _noteUsed(entry);
    _addAliases(entry, aliases);
    _addAliases(entry, _derivedAliases(entry));
    return entry;
  }

  /// Words of a full name that stand for it on their own, so a surname or
  /// the start of a company name does not slip through: the first and last
  /// word of a person's name, the first word of an organisation's. Ordinary
  /// words, particles and words that are another entity's name are skipped.
  List<String> _derivedAliases(PseudonymEntry entry) {
    final words = _words(entry.name);
    if (words.length < 2) return const [];
    final picks = switch (entry.kind) {
      PseudonymKind.person => [words.first, words.last],
      PseudonymKind.org => [words.first],
      PseudonymKind.place => const <String>[],
    };
    bool owned(String w) => _entries.values.any((o) =>
        !identical(o, entry) &&
        o.surfaces.any((s) => s.toLowerCase() == w.toLowerCase()));
    return [
      for (final w in picks)
        // An ordinary word that is part of a name (Mark, Rose, Hill) still
        // stands for it, but through the word-name rules: a capital, and a
        // use that looks like a name. Function words and particles never do.
        if (w.length >= 2 &&
            !_particles.contains(w.toLowerCase()) &&
            !_stopWords.contains(w.toLowerCase()) &&
            !owned(w))
          w,
    ];
  }

  static const _stopWords = {
    'the', 'a', 'an', 'of', 'and', 'for', 'in', 'on', 'at', 'to', 'by', 'with',
    'my', 'our', 'your', 'his', 'her', 'their', 'this', 'that', 'is', 'it',
    'inc', 'llc', 'ltd', 'co', 'corp',
  };

  static const _particles = {
    'de', 'da', 'di', 'do', 'du', 'del', 'der', 'den', 'van', 'von', 'bin',
    'ibn', 'al', 'el', 'la', 'le', 'st', 'jr', 'sr', 'ii', 'iii', 'mr', 'mrs',
    'ms', 'dr',
  };

  /// A real name in the graph (or the user's text) that equals a stand-in
  /// already issued would be turned into someone else on the way back. The
  /// stand-in is reissued and the old one retired for good.
  bool _reissueCollisions() {
    final real = <String>{
      ..._reserved,
      for (final e in _entries.values)
        for (final s in e.surfaces) ..._tokens(s),
    };
    var changed = false;
    for (final e in _entries.values.toList()) {
      final clash = [e.fake, ...e.fakes.values]
          .expand((f) => _checkedTokens(e.kind, f))
          .any(real.contains);
      if (!clash) continue;
      for (final f in [e.fake, ...e.fakes.values]) {
        _retired.addAll(_tokens(f));
      }
      _used = null;
      final fresh = _strategy.next(
        kind: e.kind,
        seed: _seed(e.id),
        gender: e.gender,
        isTaken: (c) => _isTaken(c, e.kind),
      );
      e.fake = fresh;
      e.surname = null;
      e.fakes
        ..clear()
        ..[e.name] = fresh;
      for (final a in e.aliases) {
        e.fakes[a] = _aliasFake(e, a);
      }
      changed = true;
    }
    if (changed) _invalidate();
    return changed;
  }

  /// The words of a stand-in that must not be a real name: all of a
  /// person's, the first of a place's or company's ("Labs" is shared).
  static Iterable<String> _checkedTokens(PseudonymKind kind, String fake) {
    final t = _tokens(fake);
    return kind == PseudonymKind.person ? t : t.take(1);
  }

  bool _update(PseudonymEntry entry, PseudonymEntity e) {
    var changed = false;
    if (entry.name != e.name) {
      entry.name = e.name;
      entry.fakes[e.name] = entry.fake;
      changed = true;
    }
    entry.learned = false;
    changed |= _addAliases(entry, e.aliases);
    changed |= _addAliases(entry, _derivedAliases(entry));
    return changed;
  }

  bool _addAliases(PseudonymEntry entry, List<String> aliases) {
    var changed = false;
    for (final a in aliases) {
      final alias = a.trim();
      if (alias.isEmpty ||
          RegExp(r'^my\s', caseSensitive: false).hasMatch(alias) ||
          alias.toLowerCase() == entry.name.toLowerCase() ||
          entry.aliases.any((x) => x.toLowerCase() == alias.toLowerCase())) {
        continue;
      }
      entry.aliases.add(alias);
      entry.fakes[alias] = _aliasFake(entry, alias);
      _noteUsed(entry);
      changed = true;
    }
    return changed;
  }

  /// The stand-in for an alias, so that "Priya Raman" and "Priya" and "Sam"
  /// and "Samantha" read as one person to the model: the alias's words map
  /// to the matching words of the stand-in.
  String _aliasFake(PseudonymEntry entry, String alias) {
    final name = _words(entry.name);
    final al = _words(alias);
    final fake = _words(entry.fake);
    bool eq(List<String> a, List<String> b) {
      for (var i = 0; i < a.length; i++) {
        if (a[i].toLowerCase() != b[i].toLowerCase()) return false;
      }
      return true;
    }

    if (al.length < name.length) {
      if (eq(al, name)) return fake.take(al.length).join(' ');
      if (eq(al, name.sublist(name.length - al.length))) {
        return fake.sublist((fake.length - al.length).clamp(0, fake.length)).join(' ');
      }
    } else if (al.length > name.length && eq(name, al)) {
      if (entry.kind == PseudonymKind.person) {
        entry.surname ??= _strategy.surname(
          seed: _seed(entry.id),
          isTaken: (c) => _isTakenToken(c.toLowerCase()),
        );
        return '${entry.fake} ${entry.surname}';
      }
      return entry.fake;
    }
    // A nickname or a different spelling: the same person, the same stand-in.
    return entry.kind == PseudonymKind.person ? fake.first : entry.fake;
  }

  bool _isTaken(String candidate, PseudonymKind kind) {
    if (!isPlausibleFake(candidate, kind)) return true;
    // A person's stand-in is checked word by word; a town's or company's by
    // its first word ("Labs", "Group" are shared by many).
    return _checkedTokens(kind, candidate).any(_isTakenToken);
  }

  bool _isTakenToken(String token) =>
      _reserved.contains(token) ||
      _retired.contains(token) ||
      _usedTokens().contains(token);

  /// Lowercase words of every real surface and every stand-in in the map.
  /// Kept up to date as entries are added; rebuilt after a forget.
  Set<String>? _used;
  Set<String> _usedTokens() => _used ??= {
        for (final e in _entries.values) ...[
          for (final s in e.surfaces) ..._tokens(s),
          ..._tokens(e.fake),
          for (final f in e.fakes.values) ..._tokens(f),
        ],
      };
  void _noteUsed(PseudonymEntry e) {
    final used = _used;
    if (used == null) return;
    for (final s in e.surfaces) {
      used.addAll(_tokens(s));
    }
    used.addAll(_tokens(e.fake));
    for (final f in e.fakes.values) {
      used.addAll(_tokens(f));
    }
  }

  bool _isStandIn(String text) {
    _buildBack();
    return _back!.containsKey(_norm(text));
  }

  // --- real -> fake ---------------------------------------------------------

  /// Replaces every known real name in [text] with its stand-in: exact
  /// matches on a name or alias, then near misses by spelling and sound
  /// ("Pria" for Priya, even at the start of a sentence). Names that are also
  /// words (Will, June, Rose) are replaced only where the use looks like a
  /// name. Names the map does not know stay; see PseudonymService for those.
  Dehydrated dehydrate(String text) {
    // 0. A stand-in that is already in the user's own words would be turned
    // into someone else on the way back: that word is a real name, so it
    // becomes an entity of its own and the old holder of the stand-in gets a
    // new one. Done before matching so the text is swapped with the final map.
    var mapChanged = false;
    _buildBack();
    if (_backRegex != null) {
      final seen = <String>{};
      for (final m in _backRegex!.allMatches(text).toList()) {
        final key = _norm(m[0]!);
        final back = _back![key];
        if (back == null || !seen.add(key)) continue;
        _create(slugify(m[0]!), m[0]!, back.entry.kind, const [], null,
            learned: true);
        mapChanged = true;
      }
      if (mapChanged) {
        _invalidate();
        _reissueCollisions();
      }
    }

    final found = <_Match>[];
    final rejected = <(int, int)>[];
    bool overlaps(int s, int e) => found.any((f) => s < f.end && e > f.start);
    bool rejectedAt(int s, int e) => rejected.any((r) => s < r.$2 && e > r.$1);

    // 1. exact, longest surface first
    for (final s in _surfaces()) {
      for (final m in s.regex.allMatches(text)) {
        if (overlaps(m.start, m.end)) continue;
        if (s.word) {
          // Name-words: the name's own capitalisation or ALL CAPS, never
          // lowercase, and only where the use looks like a name.
          final t = m[0]!;
          if (t != s.form && t != s.form.toUpperCase()) continue;
          if (!wordNameLooksLikeName(s.form, text, m.start, m.end)) {
            rejected.add((m.start, m.end));
            continue;
          }
        }
        found.add(_Match(m.start, m.end, s.entry, s.form, m[0]!));
      }
    }

    // 2. near misses
    final tokens = _capitalised(text);
    final index = _surfaces();
    final multi = index.where((s) => s.form.contains(' ') && _isLatin(s.form));
    for (final s in multi) {
      final n = s.form.split(RegExp(r'\s+')).length;
      for (var i = 0; i + n <= tokens.length; i++) {
        final win = tokens.sublist(i, i + n);
        var adjacent = true;
        for (var k = 1; k < n; k++) {
          if (text.substring(win[k - 1].end, win[k].start).trim().isNotEmpty) {
            adjacent = false;
          }
        }
        if (!adjacent) continue;
        final start = win.first.start, end = win.last.end;
        if (overlaps(start, end) || rejectedAt(start, end)) continue;
        final cand = text.substring(start, end);
        if (cand.toLowerCase() == s.form.toLowerCase()) continue;
        final d = editDistance(composeLatin(cand), composeLatin(s.form));
        if (d >= 1 &&
            d <= (s.form.length * 0.12).ceil() &&
            cand[0].toLowerCase() == s.form[0].toLowerCase()) {
          found.add(_Match(start, end, s.entry, s.form, cand, fuzzy: true));
        }
      }
    }
    final singles =
        index.where((s) => !s.form.contains(' ') && _isLatin(s.form)).toList();
    final standIns = _standInTokens();
    for (final tk in tokens) {
      if (overlaps(tk.start, tk.end) || rejectedAt(tk.start, tk.end)) continue;
      final lower = tk.word.toLowerCase();
      // An ordinary word is never a misspelled name, wherever it stands in a
      // sentence. A name that merely starts a sentence is still a name.
      if (tk.word.length < 3 || commonWords.contains(lower)) continue;
      if (standIns.contains(lower)) continue;
      // The closest known name wins; a tie between two different people
      // means we cannot tell whose spelling this is, so it is not assigned.
      _Surface? best;
      var bestD = 99;
      var tie = false;
      for (final s in singles) {
        if (tk.word[0].toLowerCase() != s.form[0].toLowerCase()) continue;
        final d = editDistance(composeLatin(tk.word), composeLatin(s.form));
        if (d == 0) continue;
        final len = tk.word.length < s.form.length ? tk.word.length : s.form.length;
        final ok = s.word
            ? len >= 3 && d == 1
            : len >= 4 &&
                (d <= 1 || (d <= 2 && len >= 5 && soundex(tk.word) == soundex(s.form)));
        if (!ok) continue;
        if (d < bestD) {
          best = s;
          bestD = d;
          tie = false;
        } else if (d == bestD && !identical(s.entry, best!.entry)) {
          tie = true;
        }
      }
      if (best != null && !tie) {
        found.add(_Match(tk.start, tk.end, best.entry, best.form, tk.word,
            fuzzy: true));
      }
    }

    found.sort((a, b) => a.start.compareTo(b.start));
    final out = StringBuffer();
    final replacements = <Replacement>[];
    var pos = 0;
    for (final f in found) {
      out.write(text.substring(pos, f.start));
      final rep = f.entry.fakes[f.surface] ?? f.entry.fake;
      if (!f.fuzzy) {
        (_spellings[_norm(rep)] ??= {}).add(f.surface);
      }
      replacements.add(Replacement(
        start: f.start,
        end: f.end,
        outStart: out.length,
        original: f.original,
        replacement: rep,
        entityId: f.entry.id,
        fuzzy: f.fuzzy,
      ));
      out.write(rep);
      pos = f.end;
    }
    out.write(text.substring(pos));
    return Dehydrated(
      original: text,
      text: out.toString(),
      replacements: replacements,
      mapChanged: mapChanged,
    );
  }

  // --- fake -> real ---------------------------------------------------------

  /// Puts real names back into text a model produced. This is not the
  /// inverse of [dehydrate] for a given string (that is [Dehydrated.restore]):
  /// it maps each stand-in to one name. Whole words only, any casing,
  /// possessives included ("Anika's" -> "Priya's"; "Anika-Rose" is left
  /// alone). A name the model invented, one the map did not issue, stays as
  /// it is. The name returned is the spelling the user sent for that person
  /// since the last [sync] when they used only one ("Sam" if only "Sam" was
  /// sent), otherwise the entity's own name.
  String rehydrateModelOutput(String text) {
    _buildBack();
    final re = _backRegex;
    if (re == null) return text;
    return text.replaceAllMapped(re, (m) {
      final key = _norm(m[0]!);
      final back = _back![key];
      if (back == null) return m[0]!;
      final used = _spellings[key];
      final name = used != null && used.length == 1 ? used.first : back.surface;
      return _matchCase(m[0]!, name);
    });
  }

  /// [rehydrateModelOutput] over every string in a decoded JSON value (maps, lists,
  /// strings), for a result that comes back structured. Keys are left alone.
  /// With [slugs], strings that look like an id (lowercase, hyphenated) get
  /// the stand-in's slug replaced by the real one's.
  Object? rehydrateJson(Object? value, {bool slugs = false}) {
    if (value is String) {
      if (slugs && _slugRe.hasMatch(value)) return _rehydrateSlug(value);
      return rehydrateModelOutput(value);
    }
    if (value is List) return [for (final v in value) rehydrateJson(v, slugs: slugs)];
    if (value is Map) {
      return {
        for (final e in value.entries) e.key: rehydrateJson(e.value, slugs: slugs),
      };
    }
    return value;
  }

  static final _slugRe = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  String _rehydrateSlug(String id) {
    _buildBack();
    final pairs = <(String, String)>[];
    for (final b in _back!.values) {
      final from = slugify(b.entry.fakes[b.surface] ?? b.entry.fake);
      final to = slugify(b.surface);
      if (from.isNotEmpty && to.isNotEmpty && from != to) pairs.add((from, to));
    }
    pairs.sort((a, b) => b.$1.length.compareTo(a.$1.length));
    var s = '-$id-';
    for (final p in pairs) {
      s = s.replaceAll('-${p.$1}-', '-${p.$2}-');
    }
    return s.substring(1, s.length - 1);
  }

  // --- indexes --------------------------------------------------------------

  void _invalidate() {
    _surfaceIndex = null;
    _used = null;
    _backRegex = null;
    _back = null;
  }

  List<_Surface> _surfaces() {
    final cached = _surfaceIndex;
    if (cached != null) return cached;
    final out = <_Surface>[];
    for (final e in _entries.values) {
      for (final form in e.surfaces) {
        if (form.trim().isEmpty) continue;
        final latin = _isLatin(form);
        final word = latin && !form.contains(' ') && isWordName(form);
        final pattern = latin ? '$_before${_pattern(form)}$_after' : _pattern(form);
        out.add(_Surface(
          form,
          e,
          RegExp(pattern, unicode: true, caseSensitive: false),
          word,
        ));
      }
    }
    out.sort((a, b) => b.form.length.compareTo(a.form.length));
    return _surfaceIndex = out;
  }

  void _buildBack() {
    if (_back != null) return;
    final back = <String, ({PseudonymEntry entry, String surface})>{};
    for (final e in _entries.values) {
      for (final surface in e.surfaces) {
        final fake = e.fakes[surface];
        if (fake == null) continue;
        // The first surface to claim a stand-in wins: the name before its
        // aliases.
        back.putIfAbsent(_norm(fake), () => (entry: e, surface: surface));
      }
    }
    _back = back;
    if (back.isEmpty) {
      _backRegex = null;
      return;
    }
    final forms = back.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    _backRegex = RegExp(
      '$_backBefore(?:${forms.map(_pattern).join('|')})$_backAfter',
      unicode: true,
      caseSensitive: false,
    );
  }

  Set<String> _standInTokens() {
    _buildBack();
    return {for (final k in _back!.keys) ...k.split(' ')};
  }

  // --- small helpers --------------------------------------------------------

  static Set<String> _tokens(String s) =>
      s.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toSet();

  static List<String> _words(String s) =>
      s.trim().split(RegExp(r'[\s-]+')).where((t) => t.isNotEmpty).toList();

  static String _norm(String s) => _words(s).join(' ').toLowerCase();

  static int _seed(String id) {
    var h = 0x811c9dc5;
    for (final u in id.codeUnits) {
      h = ((h ^ u) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  static final _capRe = RegExp(r"\p{Lu}[\p{L}\p{M}'’-]*", unicode: true);
  static final _possessive = RegExp("['’]s\$");

  static List<({int start, int end, String word})> _capitalised(String text) {
    final out = <({int start, int end, String word})>[];
    for (final m in _capRe.allMatches(text)) {
      var w = m[0]!.replaceFirst(_possessive, '');
      w = w.replaceFirst(RegExp("['’-]+\$"), '');
      if (w.isEmpty || !_isLatin(w)) continue;
      out.add((start: m.start, end: m.start + w.length, word: w));
    }
    return out;
  }

  static String _matchCase(String original, String replacement) {
    final letters = original.replaceAll(RegExp(r'[^\p{L}]', unicode: true), '');
    if (letters.length >= 2 && letters == letters.toUpperCase() && letters != letters.toLowerCase()) {
      return replacement.toUpperCase();
    }
    return replacement;
  }
}
