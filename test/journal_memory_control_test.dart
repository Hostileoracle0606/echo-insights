// LM-29 through the real JournalNotifier: removing an entity hides it at
// once, Undo restores it within the window, the RPC fires only after the
// window (or as soon as the app goes to the background), and an edit applies
// locally before the server call. Only the services are fakes.
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/services/memory_control_service.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/services/transcript_store.dart';
import 'package:lumen/services/turn_journal_service.dart';

const _notebookId = '8e03b8f4-4f20-4df3-8398-d854adc32b14';
final _seen = DateTime.utc(2026, 10, 20);

Entity _entity(String id, String name, {String? description}) => Entity(
      id: id,
      name: name,
      type: EntityType.person,
      description: description,
      metadata: const {},
      mentions: 1,
      firstSeen: _seen,
      lastSeen: _seen,
    );

JournalState _serverState() => JournalState(
      entries: [
        JournalEntry(
          id: 'entry-1',
          text: 'Priya and Maya.',
          createdAt: _seen,
          entityIds: const ['priya', 'maya'],
          relationIds: const ['priya__friend_of__maya'],
        ),
      ],
      entities: {
        'priya': _entity('priya', 'Priya'),
        'maya': _entity('maya', 'Maya', description: 'A friend.'),
      },
      relations: {
        'priya__friend_of__maya': Relation(
          id: 'priya__friend_of__maya',
          source: 'priya',
          target: 'maya',
          label: 'friend_of',
          metadata: const {},
          createdAt: _seen,
        ),
      },
      followUps: const [],
    );

class _FakeCommits implements NotebookCommitService {
  int snapshots = 0;

  @override
  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async {
    snapshots += 1;
    return NotebookSnapshot(
      notebookId: notebookId,
      revision: 3,
      state: _serverState(),
      suppressedEntityIds: const {'ravi'},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMemory implements MemoryControlService {
  final removed = <String>[];
  final edits = <(String, String)>[];
  bool fail = false;

  @override
  Future<int> removeEntity(String entityId) async {
    if (fail) throw Exception('offline');
    removed.add(entityId);
    return 1;
  }

  @override
  Future<int> editDescription(String entityId, String text) async {
    if (fail) throw Exception('offline');
    edits.add((entityId, text));
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTurnJournal implements TurnJournalService {
  @override
  Future<List<TurnJournalCheckpoint>> loadCheckpoints(String notebookId) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// An earlier conversation, so the notebook opens quietly (no live session).
class _FakeTranscripts implements TranscriptStore {
  @override
  Future<List<ConversationTurn>> load(String notebookId, {int limit = 500}) async =>
      const [
        ConversationTurn(
          turnId: 'saved-1',
          role: Speaker.user,
          text: 'I met Priya.',
          createdAt: '2026-10-20T12:00:00.000Z',
        ),
      ];

  @override
  Future<void> save(String notebookId, ConversationTurn turn) async {}
}

class _Harness {
  _Harness() {
    container = ProviderContainer(overrides: [
      notebookCommitServiceProvider.overrideWithValue(commits),
      memoryControlServiceProvider.overrideWithValue(memory),
      turnJournalServiceProvider.overrideWithValue(_FakeTurnJournal()),
      transcriptStoreProvider.overrideWithValue(_FakeTranscripts()),
    ]);
  }

  final commits = _FakeCommits();
  final memory = _FakeMemory();
  late final ProviderContainer container;

  JournalNotifier get journal => container.read(journalProvider.notifier);
  JournalState get state => container.read(journalProvider);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  void goToBackground() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  test('the snapshot loads the suppressed ids', () {
    fakeAsync((async) {
      final h = _Harness();
      h.journal.enterNotebook(_notebookId);
      async.flushMicrotasks();

      expect(h.journal.suppressedEntityIds, {'ravi'});
      h.container.dispose();
    });
  });

  test('remove hides the entity at once and sends after the undo window', () {
    fakeAsync((async) {
      final h = _Harness();
      h.journal.enterNotebook(_notebookId);
      async.flushMicrotasks();

      RemovalOutcome? outcome;
      h.journal.removeEntity('priya').then((value) => outcome = value);
      async.flushMicrotasks();

      expect(h.state.entities.keys, ['maya']);
      expect(h.state.relations, isEmpty);
      expect(h.state.entries.single.entityIds, ['maya']);
      expect(h.state.entries.single.relationIds, isEmpty);
      expect(h.journal.suppressedEntityIds, containsAll(['priya', 'ravi']));

      async.elapse(const Duration(seconds: 4));
      expect(h.memory.removed, isEmpty, reason: 'still inside the undo window');

      async.elapse(const Duration(seconds: 2));
      expect(h.memory.removed, ['priya']);
      expect(outcome, RemovalOutcome.removed);
      h.container.dispose();
    });
  });

  test('undo inside the window restores the entity and never sends', () {
    fakeAsync((async) {
      final h = _Harness();
      h.journal.enterNotebook(_notebookId);
      async.flushMicrotasks();

      RemovalOutcome? outcome;
      h.journal.removeEntity('priya').then((value) => outcome = value);
      async.elapse(const Duration(seconds: 2));

      expect(h.journal.undoRemove('priya'), isTrue);
      async.flushMicrotasks();

      expect(h.state.entities.keys, containsAll(['priya', 'maya']));
      expect(h.state.relations.keys, ['priya__friend_of__maya']);
      expect(h.state.entries.single.entityIds, ['priya', 'maya']);
      expect(h.state.entries.single.relationIds, ['priya__friend_of__maya']);
      expect(h.journal.suppressedEntityIds, isNot(contains('priya')));
      expect(outcome, RemovalOutcome.undone);

      async.elapse(const Duration(seconds: 10));
      expect(h.memory.removed, isEmpty);
      h.container.dispose();
    });
  });

  test('undoing one of two pending removals keeps the other hidden', () {
    fakeAsync((async) {
      final h = _Harness();
      h.journal.enterNotebook(_notebookId);
      async.flushMicrotasks();

      h.journal.removeEntity('maya');
      h.journal.removeEntity('priya');
      expect(h.journal.undoRemove('maya'), isTrue);

      expect(h.state.entities.keys, ['maya']);
      expect(h.state.relations, isEmpty);
      expect(h.state.entries.single.entityIds, ['maya']);
      expect(h.state.entries.single.relationIds, isEmpty);

      async.elapse(const Duration(seconds: 6));
      expect(h.memory.removed, ['priya']);
      h.container.dispose();
    });
  });

  test('undo after the removal was sent does nothing', () {
    fakeAsync((async) {
      final h = _Harness();
      h.journal.enterNotebook(_notebookId);
      async.flushMicrotasks();

      h.journal.removeEntity('priya');
      async.elapse(const Duration(seconds: 6));

      expect(h.journal.undoRemove('priya'), isFalse);
      expect(h.state.entities.keys, ['maya']);
      h.container.dispose();
    });
  });

  test('going to the background sends a pending removal straight away', () {
    fakeAsync((async) {
      final h = _Harness();
      h.journal.enterNotebook(_notebookId);
      async.flushMicrotasks();

      h.journal.removeEntity('priya');
      async.elapse(const Duration(seconds: 1));
      goToBackground();
      async.flushMicrotasks();

      expect(h.memory.removed, ['priya']);
      async.elapse(const Duration(seconds: 10));
      expect(h.memory.removed, ['priya'], reason: 'sent exactly once');
      h.container.dispose();
    });
  });

  test('a snapshot reload during the window keeps the entity hidden', () {
    fakeAsync((async) {
      final h = _Harness();
      h.journal.enterNotebook(_notebookId);
      async.flushMicrotasks();

      h.journal.removeEntity('priya');
      // Editing another entity fails and reloads the server snapshot, which
      // still has Priya: the pending removal must survive it.
      h.memory.fail = true;
      h.journal.editEntityDescription('maya', 'x').catchError((_) {});
      async.flushMicrotasks();

      expect(h.commits.snapshots, 2);
      expect(h.state.entities.keys, ['maya']);
      h.container.dispose();
    });
  });

  test('a failed removal brings the entity back and says so', () {
    fakeAsync((async) {
      final h = _Harness();
      h.journal.enterNotebook(_notebookId);
      async.flushMicrotasks();

      RemovalOutcome? outcome;
      h.journal.removeEntity('priya').then((value) => outcome = value);
      h.memory.fail = true;
      async.elapse(const Duration(seconds: 6));

      expect(outcome, RemovalOutcome.failed);
      expect(h.state.entities.keys, containsAll(['priya', 'maya']));
      expect(h.journal.suppressedEntityIds, isNot(contains('priya')));
      h.container.dispose();
    });
  });

  test('edit applies locally, marks it user-written, then calls the RPC', () {
    fakeAsync((async) {
      final h = _Harness();
      h.journal.enterNotebook(_notebookId);
      async.flushMicrotasks();

      h.journal.editEntityDescription('maya', '  My closest friend.  ');
      final maya = h.state.entities['maya']!;
      expect(maya.description, 'My closest friend.');
      expect(maya.descriptionSource, 'user');

      async.flushMicrotasks();
      expect(h.memory.edits, [('maya', 'My closest friend.')]);
      expect(h.commits.snapshots, 1, reason: 'no reload when the edit lands');
      h.container.dispose();
    });
  });

  test('a failed edit reloads the snapshot', () {
    fakeAsync((async) {
      final h = _Harness();
      h.journal.enterNotebook(_notebookId);
      async.flushMicrotasks();

      h.memory.fail = true;
      Object? error;
      h.journal
          .editEntityDescription('maya', 'My closest friend.')
          .catchError((Object e) => error = e);
      async.flushMicrotasks();

      expect(error, isNotNull);
      expect(h.commits.snapshots, 2);
      expect(h.state.entities['maya']!.description, 'A friend.');
      expect(h.state.entities['maya']!.descriptionSource, 'extracted');
      h.container.dispose();
    });
  });
}
