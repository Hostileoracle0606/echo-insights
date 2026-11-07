import 'dart:async';
import 'dart:convert';

import '../logic/pseudonym/fake_names.dart';
import '../logic/pseudonym/name_recognizer.dart';
import '../logic/pseudonym/pseudonym_map.dart';
import 'pseudonym_store.dart';

/// The user's name map, kept on the device (LM-55): loads and saves it
/// (Keychain), keeps it in step with the graph, finds new names with the
/// on-device recognizer, and swaps real names for stand-ins and back.
///
/// Nothing here is logged or sent anywhere, and no error carries a name:
/// failures are swallowed or reported without text. LM-56 wires it into the
/// model calls.
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
    this.recognizerTimeout = const Duration(seconds: 2),
  })  : _ownerId = ownerId,
        _store = store,
        _recognizer = recognizer,
        _strategy = strategy;

  final String? Function() _ownerId;
  final PseudonymStore _store;
  final NameRecognizer? _recognizer;
  final SurrogateStrategy _strategy;
  final Duration recognizerTimeout;

  PseudonymMap? _map;

  /// A sign-out could not delete the saved map: the next load deletes it
  /// before anything else and never reads it.
  bool _wipePending = false;

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

  /// The map for the signed-in user, or null when nobody is signed in. A map
  /// saved for someone else, or one that can't be read back, is discarded:
  /// starting empty is safe, using another account's names is not.
  Future<PseudonymMap?> _ensureLoaded() async {
    final owner = _ownerId();
    if (owner == null) {
      _map = null;
      return null;
    }
    if (_map != null && _map!.ownerId == owner) return _map;
    _map = null;
    if (_wipePending) {
      if (await _tryDelete()) _wipePending = false;
      // Whatever is stored may be another account's: not read.
      return _map = PseudonymMap(strategy: _strategy, ownerId: owner);
    }
    PseudonymMap? loaded;
    try {
      final saved = await _store.read();
      if (saved != null) {
        loaded = PseudonymMap.fromJson(
          jsonDecode(saved) as Map<String, dynamic>,
          strategy: _strategy,
        );
        if (loaded.ownerId != owner) {
          loaded = null;
          await _tryDelete();
        }
      }
    } catch (_) {
      loaded = null;
      await _tryDelete();
    }
    return _map = loaded ?? PseudonymMap(strategy: _strategy, ownerId: owner);
  }

  /// Adds the graph's private entities (see [PseudonymEntity.fromEntity]) and
  /// drops the [suppressed] ones. Saves if anything changed.
  Future<void> sync(
    Iterable<PseudonymEntity> entities, {
    Iterable<String> allNames = const [],
    Set<String> suppressed = const {},
  }) =>
      _serial(() async {
        final map = await _ensureLoaded();
        if (map == null) return;
        if (map.sync(entities, allNames: allNames, suppressed: suppressed)) {
          await _save(map);
        }
      });

  /// Swaps the real names in [text] for stand-ins. New names the recognizer
  /// finds get a stand-in first, and the map is saved before this returns,
  /// so a result that comes back later can be swapped back. If recognition
  /// fails, only names the map already knows are swapped. With nobody signed
  /// in the text comes back unchanged.
  Future<Dehydrated> dehydrate(String text) => _serial(() async {
        final map = await _ensureLoaded();
        if (map == null) {
          return Dehydrated(
            original: text,
            text: text,
            replacements: const [],
            mapChanged: false,
          );
        }
        var changed = false;
        final recognizer = _recognizer;
        if (recognizer != null && text.trim().isNotEmpty) {
          try {
            changed |= map.learn(
              await recognizer.recognize(text).timeout(recognizerTimeout),
            );
          } catch (_) {
            // Known-name swapping only.
          }
        }
        final result = map.dehydrate(text);
        if (changed || result.mapChanged) await _save(map);
        return result;
      });

  /// See [PseudonymMap.rehydrateModelOutput].
  Future<String> rehydrateModelOutput(String text) => _serial(
      () async => (await _ensureLoaded())?.rehydrateModelOutput(text) ?? text);

  /// See [PseudonymMap.rehydrateJson].
  Future<Object?> rehydrateJson(Object? value, {bool slugs = false}) => _serial(
        () async =>
            (await _ensureLoaded())?.rehydrateJson(value, slugs: slugs) ?? value,
      );

  /// Forgetting or removing an entity: its real name, aliases and stand-ins
  /// leave the map and the stand-ins are retired, so nothing re-creates it.
  Future<void> forget(String entityId) => _serial(() async {
        try {
          final map = await _ensureLoaded();
          if (map != null && map.forget(entityId)) await _save(map);
        } catch (_) {
          // Nothing readable to forget from.
        }
      });

  /// Sign-out: the map is erased from memory and the Keychain. If the
  /// Keychain delete fails the map is not read again (see [_wipePending]) and
  /// a map saved for another account is discarded at the next load anyway.
  Future<void> clear() => _serial(() async {
        _map = null;
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

  Future<void> _save(PseudonymMap map) async {
    try {
      await _store.write(jsonEncode(map.toJson()));
    } catch (_) {
      // The map still works in memory; it is written again at the next change.
    }
  }
}
