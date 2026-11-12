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

  /// Drops name-map entries for entities not in the graph any more.
  final Future<void> Function(Set<String> liveEntityIds)? pruneNames;
  final void Function(bool trusted) setBriefTrusted;
  final DateTime Function() _now;

  /// Checks started by the graph (a snapshot adopt) wait at least this long
  /// after the last good one.
  final Duration minGap;

  DateTime? _lastOk;
  Future<void> _tail = Future.value();

  /// Looks at the marker and cleans if it went up. [liveEntityIds] (the
  /// entities in the graph just loaded) lets the name map be pruned; without
  /// it the log and brief are cleaned now and the marker is kept as unseen,
  /// so the next check that has the graph finishes the job. [force] is false
  /// for checks driven by snapshots, which are throttled. Never throws.
  Future<void> check({Set<String>? liveEntityIds, bool force = true}) {
    final run = _tail.then((_) => _check(liveEntityIds, force));
    _tail = run.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return run;
  }

  Future<void> _check(Set<String>? live, bool force) async {
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
      var record = true;
      if (marker.isNewerThan(seen)) {
        try {
          await clearSharedLog();
        } catch (error) {
          debugPrint('Clearing the shared log failed: ${error.runtimeType}');
        }
        await reloadBrief();
        if (live != null) {
          try {
            await pruneNames?.call(live);
          } catch (_) {}
        } else if (pruneNames != null) {
          record = false;
        }
      }
      setBriefTrusted(true);
      _lastOk = _now();
      if (record) await _write(owner, marker);
    } catch (error) {
      debugPrint('Forget check failed: ${error.runtimeType}');
    }
  }

  /// This device made the forget itself and has cleaned up: remember the
  /// marker so the next check doesn't repeat it. Never throws.
  Future<void> acknowledge() async {
    try {
      final owner = ownerId();
      if (owner == null) return;
      final marker = ForgottenMarker.parse(await fetch());
      if (marker != null) await _write(owner, marker);
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
