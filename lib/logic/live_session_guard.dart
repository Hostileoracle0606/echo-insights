/// Identifies one attempt to own the realtime audio/transcript transport.
///
/// A lease is deliberately immutable. Callbacks capture it when they are
/// installed, so changing notebooks can invalidate the whole callback set with
/// one generation bump instead of trying to unregister each callback in time.
class LiveSessionLease {
  const LiveSessionLease._(
    this.generation, {
    this.notebookId,
    this.sessionId,
  });

  final int generation;
  final String? notebookId;
  final String? sessionId;

  LiveSessionLease bind({
    required String notebookId,
    required String sessionId,
  }) =>
      LiveSessionLease._(
        generation,
        notebookId: notebookId,
        sessionId: sessionId,
      );
}

/// Synchronously invalidates callbacks from superseded live sessions.
///
/// Closing a microphone or WebSocket is asynchronous, so shutdown alone cannot
/// stop a callback already queued by the runtime. Generation matching is the
/// correctness check; resource cancellation only saves work.
class LiveSessionGuard {
  int _generation = 0;

  LiveSessionLease begin() => LiveSessionLease._(++_generation);

  void invalidate() {
    _generation += 1;
  }

  bool isCurrent(LiveSessionLease lease) => lease.generation == _generation;
}
