// Test doubles for the name map (LM-55/56): an in-memory store, and a
// service whose map runs on the test's own isolate.
import 'package:lumen/models/entity.dart';
import 'package:lumen/services/model_inputs.dart';
import 'package:lumen/services/pseudonym_service.dart';
import 'package:lumen/services/pseudonym_store.dart';
import 'package:lumen/services/pseudonym_worker.dart';

class MemoryStore implements PseudonymStore {
  String? saved;

  @override
  Future<String?> read() async => saved;

  @override
  Future<void> write(String json) async => saved = json;

  @override
  Future<void> delete() async => saved = null;
}

PseudonymService testPseudonyms({
  String? owner = 'user-1',
  PseudonymHost? host,
  Duration refreshDelay = const Duration(seconds: 2),
}) =>
    PseudonymService(
      ownerId: () => owner,
      store: MemoryStore(),
      host: host ?? InlinePseudonymHost(),
      refreshDelay: refreshDelay,
    );

Entity entity(
  String id,
  String name, {
  EntityType type = EntityType.person,
  List<String> aliases = const [],
  int mentions = 1,
}) =>
    Entity(
      id: id,
      name: name,
      type: type,
      metadata: {if (aliases.isNotEmpty) 'aliases': aliases},
      mentions: mentions,
      firstSeen: DateTime.utc(2026, 11, 1),
      lastSeen: DateTime.utc(2026, 11, 1),
    );

/// A [ModelInputSource] that hands back fixed inputs and counts reads.
class FixedInputs implements ModelInputSource {
  FixedInputs({this.cardInput, this.briefInput});

  CardInput? cardInput;
  BriefInput? briefInput;
  int cardReads = 0;

  @override
  Future<CardInput> card(String notebookId) async {
    cardReads++;
    return cardInput ??
        const CardInput(
          revision: 7,
          turns: [
            (speaker: 'user', text: 'I had a long week.', spokenAt: null)
          ],
          candidates: [],
        );
  }

  @override
  Future<BriefInput> brief(String notebookId) async =>
      briefInput ??
      const BriefInput(
        revision: 7,
        turns: [(speaker: 'user', text: 'I had a long week.', spokenAt: null)],
        previous: null,
        followUps: [],
        questions: [],
        topEntities: [],
        entities: [],
      );
}
