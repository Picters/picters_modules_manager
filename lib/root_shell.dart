import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'binder_root.dart';

/// Result of a root-shell script run.
class ShellResult {
  const ShellResult(this.exitCode, this.stdout);

  final int exitCode;

  /// Combined stdout+stderr (the persistent session runs with `exec 2>&1`).
  final String stdout;

  bool get ok => exitCode == 0;

  /// Best-effort failure detail for an error banner — skips Java stack
  /// frames and Binder plumbing lines, keeping the actual reason above them.
  String get errorSummary {
    final lines = stdout
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return 'exit code $exitCode';
    bool isNoise(String l) =>
        l.startsWith('at ') ||
        l.startsWith('...') ||
        l.startsWith('… ') ||
        l.startsWith('Caused by:') && l.length < 12 ||
        l.contains('android.os.Binder') ||
        l.contains('com.android.internal.os') ||
        l.contains('android.os.HandlerThread');
    final meaningful = lines.where((l) => !isNoise(l)).toList();
    return (meaningful.isNotEmpty ? meaningful.last : lines.last);
  }
}

/// A single long-lived `su` process, fed one script at a time (framed by an
/// end-marker) instead of spawning `su` per command. Calls are serialized
/// through a Future chain; the session lazily restarts if the shell dies.
class RootSession {
  RootSession._();
  static final RootSession instance = RootSession._();

  Process? _proc;
  StreamQueue<String>? _lines;
  Future<void> _lock = Future.value();
  int _seq = 0;

  bool get isAlive => _proc != null;

  Future<bool> ensureStarted() async {
    if (_proc != null) return true;
    try {
      final p = await Process.start('su', const <String>[]);
      // Merge stderr into stdout so a single line stream carries everything,
      // and make the prompt-free so markers are the only framing we rely on.
      p.stdin.writeln('exec 2>&1');
      _proc = p;
      _lines = StreamQueue<String>(
        p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(
              const LineSplitter(),
            ),
      );
      // Probe: if root was denied the shell exits and this throws/times out.
      final probe = await _run('id', const Duration(seconds: 20));
      if (!probe.ok || !probe.stdout.contains('uid=0')) {
        await _kill();
        return false;
      }
      return true;
    } catch (_) {
      await _kill();
      return false;
    }
  }

  Future<bool> checkRoot() => ensureStarted();

  /// Public entry point: serialized, restarts a dead shell once.
  Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final completer = Completer<ShellResult>();
    _lock = _lock.then((_) async {
      try {
        if (_proc == null) {
          final ok = await ensureStarted();
          if (!ok) {
            completer.complete(const ShellResult(-1, 'root unavailable'));
            return;
          }
        }
        final r = await _run(script, timeout);
        completer.complete(r);
      } catch (e) {
        await _kill();
        completer.complete(ShellResult(-1, '$e'));
      }
    });
    return completer.future;
  }

  Future<ShellResult> _run(String script, Duration timeout) async {
    final proc = _proc;
    final lines = _lines;
    if (proc == null || lines == null) {
      return const ShellResult(-1, 'no session');
    }
    final marker = '__PMM_END_${_seq++}__';
    // Print the marker plus the exit status of the script's last command.
    proc.stdin.writeln('{ $script\n} 2>&1; echo "$marker:\$?"');
    await proc.stdin.flush();

    final buf = StringBuffer();
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        throw TimeoutException('root command timed out');
      }
      final bool has;
      try {
        has = await lines.hasNext.timeout(remaining);
      } on TimeoutException {
        throw TimeoutException('root command timed out');
      }
      if (!has) {
        throw const _ShellDied();
      }
      final line = await lines.next;
      final idx = line.indexOf(marker);
      if (idx >= 0) {
        final tail = line.substring(idx + marker.length + 1);
        final code = int.tryParse(tail.trim()) ?? -1;
        return ShellResult(code, buf.toString().trimRight());
      }
      buf.writeln(line);
    }
  }

  Future<void> _kill() async {
    try {
      _proc?.kill();
    } catch (_) {}
    try {
      await _lines?.cancel(immediate: true);
    } catch (_) {}
    _proc = null;
    _lines = null;
  }
}

class _ShellDied implements Exception {
  const _ShellDied();
}

/// Minimal StreamQueue so we don't need the `async` package dependency.
class StreamQueue<T> {
  StreamQueue(Stream<T> source) {
    _sub = source.listen(
      (event) {
        if (_pending != null && !_pending!.isCompleted) {
          final c = _pending!;
          _pending = null;
          c.complete(event);
        } else {
          _buffer.add(event);
        }
      },
      onDone: () {
        _closed = true;
        if (_pending != null && !_pending!.isCompleted) {
          final c = _pending!;
          _pending = null;
          c.completeError(const _ShellDied());
        }
      },
      onError: (_) {},
    );
  }

  late final StreamSubscription<T> _sub;
  final List<T> _buffer = [];
  Completer<T>? _pending;
  bool _closed = false;

  Future<bool> get hasNext async {
    if (_buffer.isNotEmpty) return true;
    if (_closed) return false;
    _pending = Completer<T>();
    try {
      final v = await _pending!.future;
      _buffer.insert(0, v);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<T> get next async {
    if (_buffer.isNotEmpty) return _buffer.removeAt(0);
    _pending = Completer<T>();
    return _pending!.future;
  }

  Future<void> cancel({bool immediate = false}) => _sub.cancel();
}

/// The one capability [ModuleRepository] needs from the root layer: run a
/// script and get its [ShellResult]. Injecting this (instead of calling the
/// [RootShell] statics directly) lets tests drive the repository with a fake
/// runner — no device, no real `su` — and assert on the exact scripts it emits.
abstract interface class RootRunner {
  Future<ShellResult> run(String script, {Duration timeout});
}

/// Production [RootRunner]: delegates straight to the [RootShell] facade
/// (Binder service when up, persistent `su` pipe otherwise). The default the
/// repository uses in the running app.
class DefaultRootRunner implements RootRunner {
  const DefaultRootRunner();

  @override
  Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) =>
      RootShell.run(script, timeout: timeout);
}

/// Facade used across the app. Routes each command through the AIDL/Binder root
/// service when enabled and connected (concurrent, no head-of-line blocking),
/// and otherwise — or on any Binder failure — through the persistent `su` pipe.
class RootShell {
  /// Route root commands through the Binder root service; the `su` pipe
  /// stays wired as an automatic fallback either way.
  static const bool useBinderService = true;

  static Future<bool> checkRoot() => RootSession.instance.checkRoot();

  /// Best-effort connect to the Binder root service (no-op unless
  /// [useBinderService]). Call once after root is granted.
  static Future<void> initBinder() async {
    if (!useBinderService) return;
    await BinderRoot.instance.tryBind();
  }

  static Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (useBinderService && BinderRoot.instance.ready) {
      try {
        return await BinderRoot.instance.exec(script, timeout);
      } catch (_) {
        // Fall through to the persistent pipe shell.
      }
    }
    return RootSession.instance.run(script, timeout: timeout);
  }
}
