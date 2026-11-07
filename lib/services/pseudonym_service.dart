import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../logic/pseudonym/fake_names.dart';
import '../logic/pseudonym/name_recognizer.dart';
import '../logic/pseudonym/pseudonym_map.dart';
import '../models/entity.dart';
import 'pseudonym_store.dart';
import 'pseudonym_worker.dart';

/// Thrown instead of sending text whose swap could not be verified (a
/// round trip that didn't restore the original). Carries no text.
class PseudonymSwapFailed implements Exception {
  const PseudonymSwapFailed();

  @override
  String toString() => 'PseudonymSwapFailed';
}

/// The user's name map, kept on the device (LM-55): loads and saves it
/// (Keychain), keeps it in step with the graph, finds new names with the
/// on-device recognizer, and swaps real names for stand-ins and back.
///
/// The map itself lives in a background isolate (see [PseudonymHost]): sync
/// and dehydrate take hundreds of milliseconds on a large graph, so they
/// never run on the UI isolate. The Keychain and the recognizer (platform
/// channels) stay here.
///
/// LM-56 wires it into the model calls: each turn is swapped once and kept
/// in memory ([swapTurns]), so closing a conversation joins cached pieces
/// instead of swapping the whole transcript.
///
/// Nothing here is logged or sent anywhere, and no error carries a name:
/// failures are swallowed or reported without text.
class PseudonymService {
  /// [ownerId] says who is signed in right now (null when nobody is). Every
  /// call checks it: the saved map belongs to one account, and with nobody
  /// signed in nothing is read, written or deleted and text passes through
  /// unchanged.
  PseudonymService({
    required String? Function() ownerId,
    required PseudonymStore store,
    NameRecognizer? recognizer,
    SurrogateStrategy strategy = const FakeNameStrategy(),
    PseudonymHost? host,
    this.recognizerTimeout = const Duration(seconds: 2),
    this.refreshDelay = const Duration(seconds: 2),
    this.maxCachedPieces = 2000,
  })  : _ownerId = ownerId,
        _store = store,
        _recognizer = recognizer,
        _strategy = strategy,
        _host = host ?? IsolatePseudonymHost();

  final String? Function() _ownerId;
  final PseudonymStore _store;
  final NameRecognizer? _recognizer;
  final SurrogateStrategy _strategy;
  final PseudonymHost _host;
  final Duration recognizerTimeout;

  /// How long after the map changes the cached turns are swapped again in
  /// the background.
  final Duration refreshDelay;
  final int maxCachedPieces;

  /// Whose map the host holds, or null when it holds none.
  String? _loadedOwner;

  /// A sign-out could not delete the saved map: the next load deletes it
  /// before anything else and never reads it.
  bool _wipePending = false;

  /// Bumped whenever the map changes. A cached piece the change could
  /// affect keeps its older version and is swapped again before it is used;
  /// the others move to the new version as they are.
  int _version = 0;

  /// Graphs (and graph slices) recently passed to [sync], so syncing an
  /// unchanged one costs only its hash.
  final _syncedGraphs = <int>[];

  final _pieces = <String, _Piece>{};
  Timer? _refreshTimer;

  /// Pieces of text the map swapped (counts only, for tests): the leave
  /// path must find every turn already swapped.
  @visibleForTesting
  int swappedPieces = 0;

  /// The longest single text the map swapped, in characters (for tests).
  @visibleForTesting
  int longestSwap = 0;

  // Calls run one at a time: a save never overlaps the next read of the map,
  // and a sign-out's clear finishes before whatever follows it.
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() job) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await job());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// Loads the saved map for the signed-in user ahead of the first call.
  Future<void> load() => _serial(_ensureLoaded);

  /// The signed-in user whose map the host now holds, or null when nobody is
  /// signed in. A map saved for someone else, or one that can't be read
  /// back, is discarded: starting empty is safe, using another account's
  /// names is not.
  Future<String?> _ensureLoaded() async {
    final owner = _ownerId();
    if (owner == null) {
      if (_loadedOwner != null) await _drop();
      return null;
    }
    if (_loadedOwner == owner) return owner;
    await _drop();
    if (_wipePending) {
      if (await _tryDelete()) _wipePending = false;
      // Whatever is stored may be another account's: not read.
      await _host.run(_LoadJob(null, owner, _strategy));
      return _loadedOwner = owner;
    }
    String? saved;
    var unreadable = false;
    try {
      saved = await _store.read();
    } catch (_) {
      unreadable = true;
    }
    final kept = await _host.run(_LoadJob(saved, owner, _strategy));
    if (!kept && (unreadable || saved != null)) await _tryDelete();
    return _loadedOwner = owner;
  }

  /// Empties the host and everything derived from the map.
  Future<void> _drop() async {
    _loadedOwner = null;
    _syncedGraphs.clear();
    _pieces.clear();
    _refreshTimer?.cancel();
    _version++;
    await _host.run(const _ResetJob());
  }

  /// The map changed; [tokens] are the lowercase words of every name,
  /// alias and stand-in the change added, moved or removed. A cached piece
  /// whose original mentions none of the names, and whose swapped text uses
  /// none of the stand-ins, would swap the same way again, so it simply
  /// moves to the new version. The others are swapped again in the
  /// background (after [refreshDelay]), so leaving finds them ready.
  void _changed(Set<String> tokens) {
    final before = _version++;
    var stale = false;
    for (final piece in _pieces.values) {
      if (piece.version != before) {
        stale = true;
        continue;
      }
      if (_mentions(piece.original, tokens) ||
          _mentions(piece.swapped, tokens)) {
        stale = true;
      } else {
        piece.version = _version;
      }
    }
    if (stale) {
      _refreshTimer?.cancel();
      _refreshTimer = Timer(refreshDelay, () => unawaited(refreshCached()));
    }
  }

  static bool _mentions(String text, Set<String> tokens) {
    if (tokens.isEmpty) return false;
    final lower = text.toLowerCase();
    return tokens.any(lower.contains);
  }

  /// Adds the graph's private entities (see [PseudonymEntity.fromEntity]) and
  /// drops the [suppressed] ones. Saves if anything changed. Skipped when
  /// the graph is the one passed last time: call it freely, it costs only a
  /// hash when nothing changed.
  Future<void> sync(
    Iterable<PseudonymEntity> entities, {
    Iterable<String> allNames = const [],
    Set<String> suppressed = const {},
  }) {
    final list = entities.toList(growable: false);
    final names = allNames.toList(growable: false);
    final dropped = suppressed.toSet();
    final graph = Object.hash(
      Object.hashAll([
        for (final e in list)
          Object.hash(
              e.id, e.name, e.kind, e.gender, Object.hashAll(e.aliases)),
      ]),
      Object.hashAll(names),
      Object.hashAllUnordered(dropped),
    );
    return _serial(() async {
      final owner = await _ensureLoaded();
      if (owner == null || _syncedGraphs.contains(graph)) return;
      final (saved, tokens) = await _host.run(_SyncJob(list, names, dropped));
      _remember(graph);
      if (saved != null) {
        _changed(tokens);
        await _save(saved);
      }
    });
  }

  /// [sync] from graph entities: which of them are private identifiers, and
  /// how, is worked out in the background too. Every entity's name is kept
  /// out of the stand-in pool.
  Future<void> syncGraph(Iterable<Entity> entities) {
    final list = entities.toList(growable: false);
    final graph = Object.hashAll([
      for (final e in list)
        Object.hash(
          e.id,
          e.name,
          e.type,
          e.description,
          jsonEncode(e.metadata['aliases']),
          e.metadata['gender'],
          e.metadata['role'],
        ),
    ]);
    return _serial(() async {
      final owner = await _ensureLoaded();
      if (owner == null || _syncedGraphs.contains(graph)) return;
      final (saved, tokens) = await _host.run(_SyncEntitiesJob(list));
      _remember(graph);
      if (saved != null) {
        _changed(tokens);
        await _save(saved);
      }
    });
  }

  void _remember(int graph) {
    _syncedGraphs.add(graph);
    if (_syncedGraphs.length > 8) _syncedGraphs.removeAt(0);
  }

  /// Swaps the real names in [text] for stand-ins. New names the recognizer
  /// finds get a stand-in first, and the map is saved before this returns,
  /// so a result that comes back later can be swapped back. If recognition
  /// fails, only names the map already knows are swapped. With nobody signed
  /// in the text comes back unchanged.
  Future<Dehydrated> dehydrate(String text) => _serial(() async {
        final owner = await _ensureLoaded();
        if (owner == null) {
          return Dehydrated(
            original: text,
            text: text,
            replacements: const [],
            mapChanged: false,
          );
        }
        return (await _swap([text])).single;
      });

  /// Swaps each of [texts] with the same map, or returns null when nobody
  /// is signed in (the caller sends nothing then). Throws
  /// [PseudonymSwapFailed] rather than return a text that didn't round-trip.
  Future<List<String>?> dehydrateAll(List<String> texts) => _serial(() async {
        if (await _ensureLoaded() == null) return null;
        return [for (final d in await _swap(texts)) d.text];
      });

  /// Swaps conversation turns, each once: a turn already swapped under the
  /// current map comes from memory, so only new turns (or ones the map has
  /// changed under) are swapped, one by one, never the whole transcript.
  /// [extras] (short context: entity names, questions) are swapped fresh
  /// with the same map. Null when nobody is signed in.
  Future<({List<String> turns, List<String> extras})?> swapTurns(
    List<String> turns, {
    List<String> extras = const [],
  }) =>
      _serial(() async {
        if (await _ensureLoaded() == null) return null;
        // A swap can teach the map a name (or move a stand-in), which
        // changes what earlier pieces should read: go round until a pass
        // changes nothing, so every piece comes from one version of the map.
        for (var pass = 0;; pass++) {
          final version = _version;
          final out = await _swapCached(turns);
          final swappedExtras = extras.isEmpty
              ? <String>[]
              : [for (final d in await _swap(extras)) d.text];
          if (version == _version || pass == 2) {
            if (version != _version) throw const PseudonymSwapFailed();
            return (turns: out, extras: swappedExtras);
          }
        }
      });

  /// Swaps the cached turns the map has changed under again, in the
  /// background (scheduled after each change), so leaving finds them ready.
  Future<void> refreshCached() => _serial(() async {
        if (await _ensureLoaded() == null) return;
        final stale = [
          for (final piece in _pieces.values)
            if (piece.version != _version) piece.original,
        ];
        if (stale.isNotEmpty) await _swapCached(stale);
      });

  // Cached by the turn's own text: the same words always swap the same way
  // under one version of the map, whoever asks (extraction, card, brief).
  Future<List<String>> _swapCached(List<String> texts) async {
    final out = List<String?>.filled(texts.length, null);
    final missing = <String>{};
    for (var i = 0; i < texts.length; i++) {
      final cached = _pieces[texts[i]];
      if (cached != null && cached.version == _version) {
        out[i] = cached.swapped;
      } else {
        missing.add(texts[i]);
      }
    }
    if (missing.isNotEmpty) {
      final list = missing.toList(growable: false);
      final swapped = await _swap(list);
      for (var j = 0; j < list.length; j++) {
        _pieces.remove(list[j]);
        _pieces[list[j]] = _Piece(list[j], swapped[j].text, _version);
      }
      for (var i = 0; i < texts.length; i++) {
        out[i] ??= _pieces[texts[i]]!.swapped;
      }
      while (_pieces.length > maxCachedPieces) {
        _pieces.remove(_pieces.keys.first);
      }
    }
    return out.cast<String>();
  }

  /// Recognizes new names in [texts] (here: a platform channel), then swaps
  /// each text separately in the host. The map is saved before returning.
  Future<List<Dehydrated>> _swap(List<String> texts) async {
    final recognized = <RecognizedName>[];
    final recognizer = _recognizer;
    if (recognizer != null) {
      for (final text in texts) {
        if (text.trim().isEmpty) continue;
        try {
          recognized.addAll(
            await recognizer.recognize(text).timeout(recognizerTimeout),
          );
        } catch (_) {
          // Known-name swapping only.
        }
      }
    }
    swappedPieces += texts.length;
    for (final text in texts) {
      if (text.length > longestSwap) longestSwap = text.length;
    }
    final (results, saved, tokens) =
        await _host.run(_SwapJob(recognized, texts));
    if (saved != null) {
      _changed(tokens);
      await _save(saved);
    }
    if (results.any((d) => !d.roundTripOk)) throw const PseudonymSwapFailed();
    return results;
  }

  /// See [PseudonymMap.rehydrateModelOutput].
  Future<String> rehydrateModelOutput(String text) =>
      _serial(() async => await _ensureLoaded() == null
          ? text
          : await _host.run(_RehydrateJob(text)));

  /// See [PseudonymMap.rehydrateJson].
  Future<Object?> rehydrateJson(Object? value, {bool slugs = false}) =>
      _serial(() async => await _ensureLoaded() == null
          ? value
          : await _host.run(_RehydrateJsonJob(value, slugs)));

  /// Forgetting or removing an entity: its real name, aliases and stand-ins
  /// leave the map and the stand-ins are retired, so nothing re-creates it.
  Future<void> forget(String entityId) => _serial(() async {
        try {
          if (await _ensureLoaded() == null) return;
          final (saved, tokens) = await _host.run(_ForgetJob(entityId));
          if (saved != null) {
            _syncedGraphs.clear();
            _changed(tokens);
            await _save(saved);
          }
        } catch (_) {
          // Nothing readable to forget from.
        }
      });

  /// Sign-out: the map is erased from memory and the Keychain. If the
  /// Keychain delete fails the map is not read again (see [_wipePending]) and
  /// a map saved for another account is discarded at the next load anyway.
  Future<void> clear() => _serial(() async {
        await _drop();
        if (!await _tryDelete()) _wipePending = true;
      });

  Future<bool> _tryDelete() async {
    try {
      await _store.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _save(String json) async {
    try {
      await _store.write(json);
    } catch (_) {
      // The map still works in memory; it is written again at the next change.
    }
  }
}

class _Piece {
  _Piece(this.original, this.swapped, this.version);
  final String original;
  final String swapped;
  int version;
}

// --- jobs (run in the host) ----------------------------------------------

String _json(PseudonymMap map) => jsonEncode(map.toJson());

/// The map's entries by id, as JSON, to tell what a change touched.
Map<String, String> _entries(PseudonymMap map) => {
      for (final e
          in (map.toJson()['entries'] as List).cast<Map<String, dynamic>>())
        e['id'] as String: jsonEncode(e),
    };

/// Lowercase words (2+ letters) of every name, alias and stand-in in an
/// entry that was added, changed or removed between [before] and [after].
Set<String> _touched(Map<String, String> before, Map<String, String> after) {
  final tokens = <String>{};
  void addEntry(String json) {
    final e = jsonDecode(json) as Map<String, dynamic>;
    final words = <String>[
      e['name'] as String,
      ...(e['aliases'] as List).cast<String>(),
      e['fake'] as String,
      ...(e['fakes'] as Map).values.cast<String>(),
      if (e['surname'] != null) e['surname'] as String,
    ];
    for (final w in words) {
      for (final t in w.toLowerCase().split(RegExp(r'[\s-]+'))) {
        if (t.length >= 2) tokens.add(t);
      }
    }
  }

  for (final id in {...before.keys, ...after.keys}) {
    final a = before[id];
    final b = after[id];
    if (a == b) continue;
    if (a != null) addEntry(a);
    if (b != null) addEntry(b);
  }
  return tokens;
}

class _ResetJob extends PseudonymJob<void> {
  const _ResetJob();
  @override
  void run(PseudonymCell cell) => cell.map = null;
}

/// Installs [saved] for [owner], or an empty map. True when [saved] was
/// used; false when there was none, it was someone else's or unreadable.
class _LoadJob extends PseudonymJob<bool> {
  const _LoadJob(this.saved, this.owner, this.strategy);
  final String? saved;
  final String owner;
  final SurrogateStrategy strategy;

  @override
  bool run(PseudonymCell cell) {
    final saved = this.saved;
    if (saved != null) {
      try {
        final loaded = PseudonymMap.fromJson(
          jsonDecode(saved) as Map<String, dynamic>,
          strategy: strategy,
        );
        if (loaded.ownerId == owner) {
          cell.map = loaded;
          return true;
        }
      } catch (_) {
        // Unreadable: start empty.
      }
    }
    cell.map = PseudonymMap(strategy: strategy, ownerId: owner);
    return false;
  }
}

/// The map's JSON when it changed (else null), and the words it touched.
class _SyncJob extends PseudonymJob<(String?, Set<String>)> {
  const _SyncJob(this.entities, this.allNames, this.suppressed);
  final List<PseudonymEntity> entities;
  final List<String> allNames;
  final Set<String> suppressed;

  @override
  (String?, Set<String>) run(PseudonymCell cell) {
    final map = cell.map!;
    final before = _entries(map);
    if (!map.sync(entities, allNames: allNames, suppressed: suppressed)) {
      return (null, const {});
    }
    return (_json(map), _touched(before, _entries(map)));
  }
}

class _SyncEntitiesJob extends PseudonymJob<(String?, Set<String>)> {
  const _SyncEntitiesJob(this.entities);
  final List<Entity> entities;

  @override
  (String?, Set<String>) run(PseudonymCell cell) => _SyncJob(
        [
          for (final e in entities)
            if (PseudonymEntity.fromEntity(e) case final p?) p,
        ],
        [for (final e in entities) e.name],
        const {},
      ).run(cell);
}

/// Learns [recognized], then swaps each text. If a swap changed the map (a
/// stand-in that turned out to be a real name moves), the texts are swapped
/// again so all of them use the final map.
class _SwapJob extends PseudonymJob<(List<Dehydrated>, String?, Set<String>)> {
  const _SwapJob(this.recognized, this.texts);
  final List<RecognizedName> recognized;
  final List<String> texts;

  @override
  (List<Dehydrated>, String?, Set<String>) run(PseudonymCell cell) {
    final map = cell.map!;
    final before = _entries(map);
    var changed = map.learn(recognized);
    var results = [for (final t in texts) map.dehydrate(t)];
    for (var pass = 0; pass < 3 && results.any((d) => d.mapChanged); pass++) {
      changed = true;
      results = [for (final t in texts) map.dehydrate(t)];
    }
    if (!changed) return (results, null, const <String>{});
    return (results, _json(map), _touched(before, _entries(map)));
  }
}

class _RehydrateJob extends PseudonymJob<String> {
  const _RehydrateJob(this.text);
  final String text;
  @override
  String run(PseudonymCell cell) => cell.map!.rehydrateModelOutput(text);
}

class _RehydrateJsonJob extends PseudonymJob<Object?> {
  const _RehydrateJsonJob(this.value, this.slugs);
  final Object? value;
  final bool slugs;
  @override
  Object? run(PseudonymCell cell) =>
      cell.map!.rehydrateJson(value, slugs: slugs);
}

class _ForgetJob extends PseudonymJob<(String?, Set<String>)> {
  const _ForgetJob(this.entityId);
  final String entityId;
  @override
  (String?, Set<String>) run(PseudonymCell cell) {
    final map = cell.map!;
    final before = _entries(map);
    if (!map.forget(entityId)) return (null, const {});
    return (_json(map), _touched(before, _entries(map)));
  }
}
