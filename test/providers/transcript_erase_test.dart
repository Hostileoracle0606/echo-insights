// R35: the opt-in erase runs as bounded server steps after the forget has
// committed, with progress, and resumes on the next launch if interrupted.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/providers/transcript_erase_provider.dart';
import 'package:lumen/services/memory_control_service.dart';

class _Server {
  _Server({this.rows = 1000, this.failAt});
  int rows;
  int? failAt;
  int calls = 0;
  final pending = <String>['job-1'];
  final steps = <String>[];

  Future<Object?> rpc(String fn, Map<String, dynamic> params) async {
    if (fn == 'forget_erase_pending') {
      return [for (final id in pending) {'id': id, 'rewritten': 0}];
    }
    if (fn == 'forget_erase_step') {
      calls += 1;
      if (failAt == calls) throw Exception('offline');
      final id = params['p_job_id'] as String;
      steps.add(id);
      final batch = params['p_batch'] as int;
      rows = rows > batch ? rows - batch : 0;
      final finished = rows == 0;
      if (finished) pending.remove(id);
      return {
        'rewritten': 1,
        'total': calls,
        'remaining': rows,
        'finished': finished,
      };
    }
    throw StateError(fn);
  }
}

({ProviderContainer container, List<int> reloads}) _container(_Server server) {
  final reloads = <int>[];
  final container = ProviderContainer(overrides: [
    memoryControlServiceProvider
        .overrideWithValue(MemoryControlService.withRpc(server.rpc)),
    eraseFinishedHookProvider.overrideWithValue(() async => reloads.add(1)),
  ]);
  addTearDown(container.dispose);
  return (container: container, reloads: reloads);
}

void main() {
  test('runs steps until the server says it is finished, with progress',
      () async {
    final server = _Server(rows: 1000);
    final c = _container(server);
    final seen = <int?>[];
    c.container.listen(transcriptEraseProvider,
        (_, next) => seen.add(next?.remaining),
        fireImmediately: false);

    final done =
        await c.container.read(transcriptEraseProvider.notifier).run('job-1');

    expect(done, isTrue);
    expect(server.calls, 4); // 300 a call
    expect(seen.where((r) => r != null), containsAllInOrder([700, 400, 100, 0]));
    expect(c.container.read(transcriptEraseProvider)!.status, EraseStatus.done);
    expect(c.reloads, [1], reason: 'the open transcript is read again once');
  });

  test('a failed step pauses it; the job stays pending for next time',
      () async {
    final server = _Server(rows: 1000, failAt: 2);
    final c = _container(server);

    final done =
        await c.container.read(transcriptEraseProvider.notifier).run('job-1');

    expect(done, isFalse);
    expect(c.container.read(transcriptEraseProvider)!.status,
        EraseStatus.paused);
    expect(server.pending, ['job-1']);
    expect(c.reloads, isEmpty);
  });

  test('resumePending runs every job the server still holds', () async {
    final server = _Server(rows: 500)..pending.add('job-2');
    final c = _container(server);

    await c.container.read(transcriptEraseProvider.notifier).resumePending();

    expect(server.steps.toSet(), {'job-1', 'job-2'});
    expect(server.pending, isEmpty);
  });

  test('one run at a time: a second call for the same job joins the first',
      () async {
    final server = _Server(rows: 600);
    final c = _container(server);
    final erase = c.container.read(transcriptEraseProvider.notifier);

    final results = await Future.wait([erase.run('job-1'), erase.run('job-1')]);

    expect(results, [true, true]);
    expect(server.calls, 2);
  });

  test('resumePending never throws', () async {
    final c = _container(_Server());
    final container = ProviderContainer(overrides: [
      memoryControlServiceProvider.overrideWithValue(
          MemoryControlService.withRpc((_, __) async => throw Exception('x'))),
    ]);
    addTearDown(container.dispose);
    await container.read(transcriptEraseProvider.notifier).resumePending();
    expect(c.reloads, isEmpty);
  });
}
