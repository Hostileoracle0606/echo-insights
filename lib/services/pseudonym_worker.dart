import 'dart:async';
import 'dart:isolate';

import '../logic/pseudonym/pseudonym_map.dart';

/// Holds the name map wherever the work on it runs (LM-56).
class PseudonymCell {
  PseudonymMap? map;
}

/// One piece of work on the map. Jobs are plain objects, not closures, so
/// nothing from the caller's isolate (a store, a channel) is captured and
/// copied across with them.
abstract class PseudonymJob<R> {
  const PseudonymJob();
  R run(PseudonymCell cell);
}

/// Where the map lives and its jobs run.
abstract interface class PseudonymHost {
  Future<R> run<R>(PseudonymJob<R> job);
}

/// Runs jobs on the calling isolate. Tests only: a large graph makes sync
/// and dehydrate take hundreds of milliseconds, which would drop frames on
/// the UI isolate.
class InlinePseudonymHost implements PseudonymHost {
  final _cell = PseudonymCell();

  @override
  Future<R> run<R>(PseudonymJob<R> job) async => job.run(_cell);
}

/// A failed job, reported by its class name only: an error from the map
/// could carry text, and nothing about a name may leave it.
class PseudonymJobFailed implements Exception {
  const PseudonymJobFailed(this.errorClass);
  final String errorClass;

  @override
  String toString() => 'PseudonymJobFailed($errorClass)';
}

/// The map in a long-lived background isolate: every sync, dehydrate and
/// rehydrate runs there, so none of them blocks the UI isolate. The isolate
/// starts on the first job and keeps the map in memory between jobs.
class IsolatePseudonymHost implements PseudonymHost {
  Future<SendPort>? _port;

  Future<SendPort> _start() async {
    final ready = ReceivePort();
    await Isolate.spawn(_main, ready.sendPort, debugName: 'pseudonym-map');
    final port = await ready.first as SendPort;
    ready.close();
    return port;
  }

  @override
  Future<R> run<R>(PseudonymJob<R> job) async {
    final port = await (_port ??= _start());
    final reply = ReceivePort();
    port.send((job, reply.sendPort));
    final (ok, value) = await reply.first as (bool, Object?);
    reply.close();
    if (!ok) throw PseudonymJobFailed(value as String);
    return value as R;
  }

  static void _main(SendPort ready) {
    final cell = PseudonymCell();
    final inbox = ReceivePort();
    ready.send(inbox.sendPort);
    inbox.listen((message) {
      final (job, reply) = message as (PseudonymJob<Object?>, SendPort);
      try {
        reply.send((true, job.run(cell)));
      } catch (error) {
        reply.send((false, error.runtimeType.toString()));
      }
    });
  }
}
