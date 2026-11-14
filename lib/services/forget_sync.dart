import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'pseudonym_store.dart';

/// How many people the account has forgotten, and when the newest forget
/// happened (`forgotten_marker()`). Nothing about who.
class ForgottenMarker {
  const ForgottenMarker(this.count, this.latest);

  final int count;
  final DateTime? latest;

  /// The RPC's row (a one-row list or the row itself). Null if unreadable.
  static ForgottenMarker? parse(Object? raw) {
    final row = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    if (row is! Map) return null;
    final count = row['forgotten_count'];
    if (count is! num) return null;
    final latest = row['latest_at'];
    return ForgottenMarker(
      count.toInt(),
      latest is String ? DateTime.tryParse(latest)?.toUtc() : null,
    );
  }

  /// Whether this is news to a device that last saw [seen]: more people, or
  /// a newer forget. Never seen counts as news when anyone is forgotten.
  bool isNewerThan(ForgottenMarker? seen) {
    if (seen == null) return count > 0;
    if (count > seen.count) return true;
    final mine = latest;
    final theirs = seen.latest;
    return mine != null && (theirs == null || mine.isAfter(theirs));
  }
}

/// A forget made on one device reaches the others (Phase 2, I2).
///
/// The server already erases what it holds. Each phone also keeps things the
/// server cannot reach: "What Lumen shared" (its speak entries carry real
/// names), the opening brief held with its audio, and the name map. At
/// sign-in, on resume and when a snapshot is adopted this asks the server
/// how many people the account has forgotten; when that went up since this
/// phone last looked, those are cleaned.
///
/// Fails closed: while the check can't be made, the held brief is not
/// played ([setBriefTrusted] false).
class ForgetSync {
  ForgetSync({
    required this.fetch,
    required this.store,
    required this.ownerId,
    required this.clearSharedLog,
    required this.reloadBrief,
    required this.setBriefTrusted,
    this.accountEntityIds,
    this.pruneNames,
    DateTime Function()? now,
    this.minGap = const Duration(minutes: 1),
  }) : _now = now ?? DateTime.now;

  /// The `forgotten_marker` response.
  final Future<Object?> Function() fetch;

  /// Where the last marker seen is kept, per owner.
  final PseudonymStore store;
  final String? Function() ownerId;
  final Future<void> Function() clearSharedLog;

  /// Reloads the brief from the server, dropping the held copy if it can't.
  final Future<void> Function() reloadBrief;

  /// Every entity id in the account, across all notebooks (the
  /// `user_entities` view), read in full. The name map spans the account, so
  /// it is only ever pruned against this, never against one notebook.
  final Future<Set<String>> Function()? accountEntityIds;

  /// Drops name-map entries for ids not in the set it is given.
  final Future<void> Function(Set<String> accountEntityIds)? pruneNames;
  final void Function(bool trusted) setBriefTrusted;
  final DateTime Function() _now;

  /// Checks started by the graph (a snapshot adopt) wait at least this long
  /// after the last good one.
  final Duration minGap;

  DateTime? _lastOk;
  Future<void> _tail = Future.value();

  /// The marker whose log and brief clean-up is done, in this run. A repeat
  /// check (a resume while the name-map prune is still owed) does not wipe
  /// the log or reload the brief again.
  ForgottenMarker? _handled;
  String? _handledOwner;

  /// Looks at the marker and cleans if it went up: the shared log, the held
  /// brief, and the name map (pruned against the whole account's entities).
  /// If the account's entities can't be read the marker is kept as unseen
  /// and the prune is retried by the next check. A [force]d check (sign-in,
  /// resume) distrusts the held brief at once, synchronously, and trusts it
  /// again only when the check succeeds; one that is not forced (driven by a
  /// snapshot) is throttled. Never throws.
  Future<void> check({bool force = true}) {
    if (force) setBriefTrusted(false);
    final run = _tail.then((_) => _check(force));
    _tail = run.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return run;
  }

  Future<void> _check(bool force) async {
    try {
      final owner = ownerId();
      if (owner == null) return;
      final last = _lastOk;
      if (!force && last != null && _now().difference(last) < minGap) return;
      final ForgottenMarker? marker;
      try {
        marker = ForgottenMarker.parse(await fetch());
        if (marker == null) throw const FormatException('marker');
      } catch (_) {
        setBriefTrusted(false);
        return;
      }
      final seen = await _read(owner);
      var finished = true;
      if (marker.isNewerThan(seen)) {
        if (_handledOwner != owner || !_same(_handled, marker)) {
          try {
            await clearSharedLog();
          } catch (error) {
            debugPrint('Clearing the shared log failed: ${error.runtimeType}');
          }
          await reloadBrief();
          _handled = marker;
          _handledOwner = owner;
        }
        final ids = accountEntityIds;
        final prune = pruneNames;
        if (ids != null && prune != null) {
          try {
            await prune(await ids());
          } catch (_) {
            finished = false;
          }
        }
      }
      setBriefTrusted(true);
      // An unfinished prune must not hold the next check back.
      _lastOk = finished ? _now() : null;
      if (finished) await _write(owner, marker);
    } catch (error) {
      debugPrint('Forget check failed: ${error.runtimeType}');
    }
  }

  static bool _same(ForgottenMarker? a, ForgottenMarker b) =>
      a != null && a.count == b.count && a.latest == b.latest;

  /// This device made a forget itself and has cleaned up: remember the
  /// marker, but only if it moved by exactly that one person since the last
  /// one seen. If it moved by more (another device forgot someone at the
  /// same time) or was never seen, it is left for the next [check], which
  /// cleans for the other device's forget too. Never throws.
  Future<void> acknowledge() async {
    try {
      final owner = ownerId();
      if (owner == null) return;
      final marker = ForgottenMarker.parse(await fetch());
      final seen = await _read(owner);
      if (marker == null || seen == null) return;
      if (marker.count == seen.count + 1) await _write(owner, marker);
    } catch (_) {}
  }

  Future<ForgottenMarker?> _read(String owner) async {
    try {
      final saved = await store.read();
      if (saved == null) return null;
      final json = jsonDecode(saved) as Map<String, dynamic>;
      if (json['owner'] != owner) return null;
      final latest = json['latest'];
      return ForgottenMarker(
        (json['count'] as num).toInt(),
        latest is String ? DateTime.tryParse(latest)?.toUtc() : null,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String owner, ForgottenMarker marker) async {
    try {
      await store.write(jsonEncode({
        'owner': owner,
        'count': marker.count,
        if (marker.latest != null) 'latest': marker.latest!.toIso8601String(),
      }));
    } catch (_) {}
  }
}
