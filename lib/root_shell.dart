import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of a root-shell script run.
class ShellResult {
  const ShellResult(this.exitCode, this.stdout);

  final int exitCode;

  /// Combined stdout+stderr (the persistent session runs with `exec 2>&1`).
  final String stdout;

  bool get ok => exitCode == 0;

  /// Best-effort human-readable failure detail for an error banner.
  String get errorSummary {
    final text = stdout.trim();
    if (text.isEmpty) return 'exit code $exitCode';
    return text.split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ??
        'exit code $exitCode';
  }
}

extension _LastOrNull<E> on Iterable<E> {
  E? get lastOrNull {
    E? result;
    for (final e in this) {
      result = e;
    }
    return result;
  }
}

/// A single long-lived `su` process. Instead of spawning `su` per command
/// (which is what makes 1-second polling expensive and noisy in the SELinux
/// audit log), we keep one root shell open and pipe each script into it,
/// framed by a unique end-marker so we know when its output is complete.
///
/// Commands are serialized through a Future chain so two callers never
/// interleave on the shared stdin/stdout. The session lazily (re)starts if the
/// shell ever dies.
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

/// Back-compat facade used across the app.
class RootShell {
  static Future<bool> checkRoot() => RootSession.instance.checkRoot();

  static Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) =>
      RootSession.instance.run(script, timeout: timeout);
}
