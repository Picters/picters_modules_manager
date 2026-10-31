import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/root_shell.dart';

Future<ShellResult> executeFramed(String script) async {
  const marker = '__TEST_ROOT_END__';
  final process = await Process.run('sh', [
    '-c',
    '{ $script\n} 2>&1; echo "$marker:\$?"',
  ]);
  expect(process.exitCode, 0);
  final frame = RootReplyFrame(marker);
  for (final line in const LineSplitter().convert(process.stdout as String)) {
    final reply = frame.addLine(line);
    if (reply != null) return reply;
  }
  throw StateError('Missing shell completion');
}

void main() {
  test(
    'real shell stdout without final LF survives its completion marker',
    () async {
      final reply = await executeFramed("printf 'YWJjbm4='");
      expect(reply.exitCode, 0);
      expect(reply.stdout, 'YWJjbm4=');
      expect(utf8.decode(base64Decode(reply.stdout)), 'abcnn');
    },
  );
  test('preserves the last unterminated line after earlier output', () async {
    final reply = await executeFramed("printf 'first\\nlast'");
    expect(reply.stdout, 'first\nlast');
  });
  test('preserves error output and the failing script status', () async {
    final reply = await executeFramed("printf 'denied' >&2; false");
    expect(reply.exitCode, 1);
    expect(reply.stdout, 'denied');
  });
}
