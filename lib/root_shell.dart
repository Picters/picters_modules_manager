import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of a root-shell script run.
class ShellResult {
  const ShellResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// Best-effort human-readable failure detail for a SnackBar.
  String get errorSummary {
    final text = stderr.trim().isNotEmpty ? stderr.trim() : stdout.trim();
    return text.isEmpty ? 'exit code $exitCode' : text.split('\n').first;
  }
}

/// Runs shell scripts through `su`, piping the script over stdin instead of
/// passing it as a `su -c "..."` argument. A single-line `su -c` can't safely
/// carry a multi-line script (quoting/escaping breaks), and stdin-piping is
/// the standard, well-supported way any KernelSU/Magisk `su` reads a script.
class RootShell {
  static Future<bool> checkRoot() async {
    try {
      final r = await run('id\n', timeout: const Duration(seconds: 15));
      return r.ok && r.stdout.contains('uid=0');
    } catch (_) {
      return false;
    }
  }

  static Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final process = await Process.start('su', const <String>[]);
    process.stdin.write(script);
    await process.stdin.close();

    final stdoutFuture =
        process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final stderrFuture =
        process.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      exitCode = -1;
    }

    final out = await stdoutFuture;
    final err = await stderrFuture;
    return ShellResult(exitCode, out, err);
  }
}
