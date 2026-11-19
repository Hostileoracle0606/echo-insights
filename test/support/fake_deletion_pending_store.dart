import 'package:lumen/services/deletion_pending_store.dart';

/// An in-memory "deletion pending" marker. Records 'markerWrite' and
/// 'markerClear' into [events] (shared with the gateway fake) so tests can
/// check the order against the function call.
class FakeDeletionPendingStore implements DeletionPendingStore {
  FakeDeletionPendingStore({List<String>? events, this.value})
      : events = events ?? [];

  final List<String> events;
  String? value;
  Object? readError;
  Object? writeError;

  @override
  Future<String?> read() async {
    if (readError != null) throw readError!;
    return value;
  }

  @override
  Future<void> write(String requestId) async {
    events.add('markerWrite');
    if (writeError != null) throw writeError!;
    value = requestId;
  }

  @override
  Future<void> clear() async {
    events.add('markerClear');
    value = null;
  }
}
