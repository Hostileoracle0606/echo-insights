import 'package:lumen/services/deletion_pending_store.dart';

/// An in-memory "deletion pending" marker. Records 'markerWrite' and
/// 'markerClear' into [events] (shared with the gateway fake) so tests can
/// check the order against the function call.
class FakeDeletionPendingStore implements DeletionPendingStore {
  FakeDeletionPendingStore({List<String>? events, String? value})
      : events = events ?? [] {
    this.value = value;
  }

  final List<String> events;
  PendingAccountDeletion? _request;
  String? get value => _request?.requestId;
  set value(String? id) {
    _request =
        id == null ? null : (userId: 'user-1', requestId: id, isApple: false);
  }

  Object? readError;
  Object? writeError;

  @override
  Future<PendingAccountDeletion?> read() async {
    if (readError != null) throw readError!;
    return _request;
  }

  @override
  Future<void> write(PendingAccountDeletion request) async {
    events.add('markerWrite');
    if (writeError != null) throw writeError!;
    _request = request;
  }

  @override
  Future<void> clear() async {
    events.add('markerClear');
    value = null;
  }
}
