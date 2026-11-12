import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../models/entity.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';
import '../services/pseudonym_store.dart';
import 'memory_removal.dart' show withoutEntity;
import 'slugify.dart';
import 'turn_state.dart' show ConversationTurn;

/// What a forgotten name becomes, as in the database.
const forgottenStandIn = 'someone';

/// Words and the gaps between them, in order.
final _token = RegExp(r'([\p{L}\p{M}\p{N}]+)|([^\p{L}\p{M}\p{N}]+)', unicode: true);

/// What may join the words of one name: spaces, hyphens, apostrophes and
/// periods (O'Brien, St. John). Anything else ends it.
final _joiner = RegExp(r"^[ \t'’.\-]+$");

/// Scripts written without spaces, and Korean: a name is looked for inside
/// a word (the database's _no_word_gaps).
final _noWordGaps = RegExp(r'[\u0E00-\u0E7F\u1100-\u11FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7A3\uF900-\uFAFF]');

/// The people the user forgot (LM-63), so nothing the app sends a model or
/// shows in a graph names them, across restarts. Lumen's reads from the
/// server are redacted there; this covers what the app holds or assembles
/// itself: the state before a reload succeeds, the turns of a session, the
/// extraction request, the graph summary.
///
/// Like the server, it keeps no name: only a keyed hash (HMAC-SHA256 with a
/// random key that never leaves the device) of each name's slug, with its
/// word count. A run of up to that many words whose slug hashes to one is a
/// match: the whole name, its words joined by spaces, hyphens, apostrophes
/// or periods, any case; a one-word name only when it starts with a capital;
/// inside a word for scripts written without spaces. Saved in the encrypted
/// store beside the name map, read at sign-in for the signed-in owner only,
/// erased at sign-out.
class ForgetRedactor {
  ForgetRedactor({PseudonymStore? store, String? Function()? ownerId})
      : _store = store,
        _ownerId = ownerId;

  final PseudonymStore? _store;
  final String? Function()? _ownerId;

  List<int>? _key;
  // Hash of each forgotten slug -> its word count.
  final Map<String, int> _hashes = {};
  // Those in a script written without spaces.
  final Set<String> _insideHashes = {};
  int _maxWords = 0;
  bool _inside = false;
  String? _loadedOwner;
  Future<void>? _loading;
  Future<void> _saving = Future.value();

  bool get isEmpty => _hashes.isEmpty;

  /// Reads the saved hashes for the signed-in owner (at sign-in, and before
  /// anything is redacted after a restart). Another owner's are discarded.
  Future<void> ensureLoaded() {
    final store = _store;
    if (store == null) return Future.value();
    final owner = _ownerId?.call();
    if (owner == null) {
      if (_loadedOwner != null) _forgetMemory();
      return Future.value();
    }
    if (_loadedOwner == owner) return Future.value();
    return _loading ??= _load(store, owner).whenComplete(() => _loading = null);
  }

  Future<void> _load(PseudonymStore store, String owner) async {
    _forgetMemory();
    String? saved;
    try {
      saved = await store.read();
    } catch (_) {
      saved = null;
    }
    var kept = false;
    if (saved != null) {
      try {
        final json = jsonDecode(saved) as Map<String, dynamic>;
        if (json['owner'] == owner) {
          _key = base64Decode(json['key'] as String);
          for (final e in (json['hashes'] as List).cast<Map<String, dynamic>>()) {
            _remember(e['h'] as String, (e['w'] as num).toInt(), e['i'] == true);
          }
          kept = true;
        }
      } catch (_) {
        _forgetMemory();
      }
      if (!kept) {
        try {
          await store.delete();
        } catch (_) {}
      }
    }
    _loadedOwner = owner;
  }

  /// Forgets [id] and every name in [names] (its own, and the names it had
  /// under other ids). Takes effect at once; [flush] waits for the save.
  void add(String id, Iterable<String> names) {
    _key ??= List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final slugs = {
      if (!id.startsWith('e-')) id,
      for (final name in names)
        if (name.trim().isNotEmpty) slugify(name),
    };
    for (final slug in slugs) {
      _remember(_hash(slug), slug.split('-').where((w) => w.isNotEmpty).length,
          _noWordGaps.hasMatch(slug));
    }
    final store = _store;
    if (store != null) {
      final json = _toJson();
      _saving = _saving.then((_) => store.write(json)).catchError((Object e) {
        // In memory it still works; the next forget saves again.
      });
    }
  }

  /// Waits until everything added is saved.
  Future<void> flush() => _saving;

  /// Sign-out: memory and the store.
  Future<void> clear() async {
    _forgetMemory();
    _loadedOwner = null;
    await _saving;
    try {
      await _store?.delete();
    } catch (_) {}
  }

  void _forgetMemory() {
    _key = null;
    _hashes.clear();
    _insideHashes.clear();
    _maxWords = 0;
    _inside = false;
  }

  void _remember(String hash, int words, bool inside) {
    _hashes[hash] = words;
    if (words > _maxWords) _maxWords = words;
    if (inside) {
      _inside = true;
      _insideHashes.add(hash);
    }
  }

  String _toJson() => jsonEncode({
        'v': 1,
        'owner': _loadedOwner ?? _ownerId?.call(),
        'key': base64Encode(_key!),
        'hashes': [
          for (final e in _hashes.entries)
            {'h': e.key, 'w': e.value, 'i': _insideHashes.contains(e.key)},
        ],
      });


  String _hash(String slug) =>
      Hmac(sha256, _key!).convert(utf8.encode(slug)).toString();

  bool _hit(String piece) => _hashes.containsKey(_hash(slugify(piece)));

  /// [text] with every forgotten name replaced by "someone".
  String redact(String text) {
    if (_hashes.isEmpty || text.isEmpty || _key == null) return text;
    final toks = <String>[];
    final word = <bool>[];
    for (final m in _token.allMatches(text)) {
      toks.add(m[0]!);
      word.add(m[1] != null);
    }
    final n = toks.length;
    var i = 0;
    while (i < n) {
      var hit = false;
      if (word[i]) {
        var run = 1;
        while (run < _maxWords &&
            i + 2 * run < n &&
            word[i + 2 * run] &&
            _joiner.hasMatch(toks[i + 2 * run - 1])) {
          run++;
        }
        for (var len = run; len >= 1; len--) {
          final k = i + 2 * (len - 1);
          if (len == 1) {
            final first = toks[i].substring(0, 1);
            if (first != first.toUpperCase()) continue;
          }
          if (_hit(toks.sublist(i, k + 1).join())) {
            toks[i] = forgottenStandIn;
            for (var g = i + 1; g <= k; g++) {
              toks[g] = '';
            }
            i = k + 1;
            hit = true;
            break;
          }
        }
        if (!hit && _inside && _noWordGaps.hasMatch(toks[i])) {
          toks[i] = _redactInside(toks[i]);
        }
      }
      if (!hit) i++;
    }
    return toks.join();
  }

  /// Runs of 2 to 8 characters inside one word (the database's
  /// _redact_inside_word).
  String _redactInside(String w) {
    final chars = w.runes.map(String.fromCharCode).toList();
    final out = StringBuffer();
    var i = 0;
    while (i < chars.length) {
      var hit = false;
      for (var len = min(8, chars.length - i); len >= 2; len--) {
        if (_hit(chars.sublist(i, i + len).join())) {
          out.write(forgottenStandIn);
          i += len;
          hit = true;
          break;
        }
      }
      if (!hit) out.write(chars[i++]);
    }
    return out.toString();
  }

  bool names(String text) => redact(text) != text;

  /// True when entity [id] named [name] is stored under another id on the
  /// server (its name names someone forgotten, and the id spells that name:
  /// made from it, or its words read as text name them). Forgetting Will
  /// leaves "will-power" (named "will power") alone, as the server does.
  bool spells(String id, String name) {
    if (isEmpty || !names(name)) return false;
    return id == slugify(name) || names(id.replaceAll('-', ' '));
  }

  /// [turn] as Lumen may read it: the server's redacted words when it sent
  /// them, then this run's names.
  ConversationTurn turnForLumen(ConversationTurn turn) {
    final text = redact(turn.contextText ?? turn.text);
    if (text == turn.text && turn.contextText == null) return turn;
    return ConversationTurn(
      turnId: turn.turnId,
      role: turn.role,
      text: text,
      createdAt: turn.createdAt,
      startedAt: turn.startedAt,
      input: turn.input,
    );
  }

  /// [state] as the server returns it after the forget: the forgotten
  /// person under any id gone, ids that spell them gone (the server renamed
  /// them), their names redacted in every other text, and questions that
  /// name them dropped. Used at the forget itself, so a failed reload can't
  /// leave their name in what Lumen is sent (BUG-5).
  JournalState redactState(JournalState state) {
    if (isEmpty) return state;
    var next = state;
    for (final e in state.entities.values) {
      if (spells(e.id, e.name) ||
          _hashes.containsKey(_hash(e.id)) ||
          redact(e.name).trim() == forgottenStandIn) {
        next = withoutEntity(next, e.id);
      }
    }
    final dropped = {
      for (final id in state.entities.keys)
        if (!next.entities.containsKey(id)) id,
    };
    return next.copyWith(
      entities: {
        for (final e in next.entities.values) e.id: _entity(e),
      },
      relations: {
        for (final r in next.relations.values)
          r.id: Relation(
            id: r.id,
            source: r.source,
            target: r.target,
            label: r.label,
            metadata: _json(r.metadata) as Map<String, dynamic>,
            createdAt: r.createdAt,
            supersededAt: r.supersededAt,
          ),
      },
      entries: [
        for (final e in next.entries)
          JournalEntry(
            id: e.id,
            text: redact(e.text),
            createdAt: e.createdAt,
            entityIds: e.entityIds,
            relationIds: e.relationIds,
          ),
      ],
      followUps: [
        for (final f in next.followUps)
          if (!names(f.question) &&
              !names(f.reason) &&
              !f.targetEntityIds.any(dropped.contains))
            f,
      ],
    );
  }

  Entity _entity(Entity e) => Entity(
        id: e.id,
        name: redact(e.name),
        type: e.type,
        description: e.description == null ? null : redact(e.description!),
        descriptionSource: e.descriptionSource,
        metadata: _json(e.metadata) as Map<String, dynamic>,
        mentions: e.mentions,
        firstSeen: e.firstSeen,
        lastSeen: e.lastSeen,
        questions: e.questions == null
            ? null
            : [for (final q in e.questions!) redact(q)],
      );

  /// Free-form JSON, keys too, as the server's _jsonb_redact_all.
  Object? _json(Object? value) => switch (value) {
        final String s => redact(s),
        final List<Object?> l => [for (final v in l) _json(v)],
        final Map<Object?, Object?> m => <String, dynamic>{
            for (final e in m.entries) redact('${e.key}'): _json(e.value),
          },
        _ => value,
      };
}
