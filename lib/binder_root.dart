import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'root_shell.dart';

/// Client for the native root command broker (KernelRootService, reached over
/// AIDL/Binder through MainActivity). Commands go out via a MethodChannel and
/// results stream back on an EventChannel, keyed by request id — so many
/// commands can be in flight at once without head-of-line blocking, unlike the
/// single serialized [RootSession] pipe.
///
/// This is strictly additive: if binding fails or a call errors, [RootShell]
/// falls back to the pipe shell, so the app degrades gracefully.
class BinderRoot {
  BinderRoot._();
  static final BinderRoot instance = BinderRoot._();

  static const MethodChannel _method =
      MethodChannel('com.picters.modulesmanager/system');
  static const EventChannel _events =
      EventChannel('com.picters.modulesmanager/system/root_events');

  bool _ready = false;
  bool get ready => _ready;

  int _nextId = 1;
  final Map<int, Completer<ShellResult>> _pending = {};
  StreamSubscription<dynamic>? _sub;

  /// Best-effort bind to the root service. Returns true once connected. Safe to
  /// call more than once; only the first bind does work.
  Future<bool> tryBind() async {
    if (_ready) return true;
    _sub ??= _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
    try {
      final ok = await _method
          .invokeMethod<bool>('bindRoot')
          .timeout(const Duration(seconds: 10));
      _ready = ok ?? false;
    } catch (_) {
      _ready = false;
    }
    debugPrint('PKM_IPC: binder tryBind ready=$_ready');
    return _ready;
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final id = event['id'] as int?;
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final err = event['err'] as String?;
    if (err != null) {
      completer.completeError(StateError(err));
    } else {
      completer.complete(
        ShellResult((event['code'] as int?) ?? -1, (event['out'] as String?) ?? ''),
      );
    }
  }

  /// Runs [script] over the Binder service. Throws (so the caller can fall back
  /// to the pipe) if the service isn't ready, rejects the call, or times out.
  Future<ShellResult> exec(String script, Duration timeout) async {
    if (!_ready) throw StateError('root service not bound');
    final id = _nextId++;
    final completer = Completer<ShellResult>();
    _pending[id] = completer;

    bool accepted;
    try {
      accepted = await _method.invokeMethod<bool>('execRoot', {
            'id': id,
            'script': script,
            'timeoutMs': timeout.inMilliseconds,
          }) ??
          false;
    } catch (_) {
      _pending.remove(id);
      _ready = false; // binder likely died — stop using it
      rethrow;
    }
    if (!accepted) {
      _pending.remove(id);
      _ready = false;
      throw StateError('root service rejected exec');
    }

    return completer.future.timeout(
      timeout + const Duration(seconds: 5),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('root exec timed out');
      },
    );
  }
}
