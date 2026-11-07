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
  PseudonymService({
    required PseudonymStore store,
    NameRecognizer? recognizer,
    SurrogateStrategy strategy = const FakeNameStrategy(),
    this.recognizerTimeout = const Duration(seconds: 2),
  })  : _store = store,
        _recognizer = recognizer,
        _strategy = strategy;

  final PseudonymStore _store;
  final NameRecognizer? _recognizer;
  final SurrogateStrategy _strategy;
  final Duration recognizerTimeout;

  PseudonymMap? _map;
  String? _owner;

  // Calls run one at a time: a save never overlaps the next read of the map.
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

  /// Loads the saved map for [ownerId] (the signed-in user). A map saved for
  /// someone else, or one that can't be read back, is discarded: starting
  /// empty is safe, using another account's names is not.
  Future<void> load({String? ownerId}) => _serial(() async {
        await _ensureLoaded(ownerId);
      });

  Future<PseudonymMap> _ensureLoaded([String? ownerId]) async {
    if (_map != null && (ownerId == null || ownerId == _owner)) return _map!;
    _owner = ownerId ?? _owner;
    PseudonymMap? loaded;
    try {
      final saved = await _store.read();
      if (saved != null) {
        loaded = PseudonymMap.fromJson(
          jsonDecode(saved) as Map<String, dynamic>,
          strategy: _strategy,
        );
        if (loaded.ownerId != _owner) {
          loaded = null;
          await _safely(_store.delete);
        }
      }
    } catch (_) {
      loaded = null;
      await _safely(_store.delete);
    }
    return _map = loaded ?? PseudonymMap(strategy: _strategy, ownerId: _owner);
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
        if (map.sync(entities, allNames: allNames, suppressed: suppressed)) {
          await _save(map);
        }
      });

  /// Swaps the real names in [text] for stand-ins. New names the recognizer
  /// finds get a stand-in first, and the map is saved before this returns,
  /// so a result that comes back later can be swapped back. If recognition
  /// fails, only names the map already knows are swapped.
  Future<Dehydrated> dehydrate(String text) => _serial(() async {
        final map = await _ensureLoaded();
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

  /// See [PseudonymMap.rehydrate].
  Future<String> rehydrate(String text) =>
      _serial(() async => (await _ensureLoaded()).rehydrate(text));

  /// See [PseudonymMap.rehydrateJson].
  Future<Object?> rehydrateJson(Object? value, {bool slugs = false}) => _serial(
        () async => (await _ensureLoaded()).rehydrateJson(value, slugs: slugs),
      );

  /// Forgetting or removing an entity: its real name, aliases and stand-ins
  /// leave the map and the stand-ins are retired, so nothing re-creates it.
  Future<void> forget(String entityId) => _serial(() async {
        try {
          final map = await _ensureLoaded();
          if (map.forget(entityId)) await _save(map);
        } catch (_) {
          // Nothing readable to forget from.
        }
      });

  /// Sign-out: the map is erased from memory and the Keychain.
  Future<void> clear() => _serial(() async {
        _map = null;
        _owner = null;
        await _safely(_store.delete);
      });

  Future<void> _save(PseudonymMap map) async {
    try {
      await _store.write(jsonEncode(map.toJson()));
    } catch (_) {
      // The map still works in memory; it is written again at the next change.
    }
  }

  Future<void> _safely(Future<void> Function() job) async {
    try {
      await job();
    } catch (_) {}
  }
}
