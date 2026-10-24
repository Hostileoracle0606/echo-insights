import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBindingObserver;

typedef StartTimer = Timer Function(Duration after, void Function() callback);

/// Removals from the closing card's "Lumen will remember" list (LM-16).
///
/// The card is shown after the notebook was left, so the journal's own undo
/// window (`JournalNotifier.removeEntity`) isn't available: this keeps the
/// same rules for one screen. A removal hides its row at once; [remove]
/// runs only once [window] passes without [undo], or straight away when the
/// app leaves the foreground or the screen goes, so a removal is never left
/// unsent. A failed one shows the row again and calls [onFailed].
class CardRemovals extends ChangeNotifier with WidgetsBindingObserver {
  CardRemovals({
    required Future<void> Function(String entityId) remove,
    this.window = const Duration(seconds: 5),
    StartTimer startTimer = Timer.new,
    this.onFailed,
  })  : _remove = remove,
        _startTimer = startTimer;

  final Future<void> Function(String entityId) _remove;
  final StartTimer _startTimer;
  final Duration window;
  final void Function(String entityId)? onFailed;

  final _pending = <String, Timer>{};
  final _hidden = <String>{};
  bool _disposed = false;

  /// True while a removal is pending or once it was sent.
  bool isHidden(String entityId) => _hidden.contains(entityId);

  void remove(String entityId) {
    if (_hidden.contains(entityId)) return;
    _hidden.add(entityId);
    _pending[entityId] = _startTimer(window, () => unawaited(_send(entityId)));
    _changed();
  }

  /// Cancels a removal still inside its window. False once it was sent.
  bool undo(String entityId) {
    final timer = _pending.remove(entityId);
    if (timer == null) return false;
    timer.cancel();
    _hidden.remove(entityId);
    _changed();
    return true;
  }

  /// Sends every removal still inside its window, now.
  Future<void> flush() => Future.wait([
        for (final id in _pending.keys.toList()) _send(id),
      ]);

  Future<void> _send(String entityId) async {
    final timer = _pending.remove(entityId);
    if (timer == null) return;
    timer.cancel();
    try {
      await _remove(entityId);
    } catch (error) {
      debugPrint('Card removal failed for $entityId: $error');
      _hidden.remove(entityId);
      _changed();
      onFailed?.call(entityId);
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(flush());
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Leaving the card inside a window is not an undo: what's pending is sent.
  @override
  void dispose() {
    unawaited(flush());
    _disposed = true;
    super.dispose();
  }
}
