import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/module_repository.dart';
import 'package:picters_modules_manager/root_shell.dart';

class _ProbeRunner implements RootRunner {
  _ProbeRunner(this.result);
  final ShellResult result;
  @override
  Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) async => result;
}

void main() {
  Future<bool?> probe(
    String release,
    String interface, {
    int exitCode = 0,
    bool complete = true,
  }) => ModuleRepository(
    _ProbeRunner(
      ShellResult(
        exitCode,
        'PMM_RELEASE:$release\nPMM_INTERFACE:$interface\n${complete ? "PMM_KERNEL_PROBE:complete" : ""}',
      ),
    ),
  ).pictersKernelDetected();

  test('kernel sysfs recognizes Picters when uname is spoofed', () async {
    expect(await probe('6.12.69-android16-6-stock', 'present'), isTrue);
  });
  test(
    'legacy Picters release remains recognized without the newer interface',
    () async {
      expect(await probe('6.12.23-android16-Picters-ReSuki', 'absent'), isTrue);
    },
  );
  test('a successful foreign-kernel probe reports missing features', () async {
    expect(await probe('6.12.69-stock', 'absent'), isFalse);
  });
  test(
    'failed, empty and truncated shell responses do not imply a foreign kernel',
    () async {
      expect(await probe('6.12.69-stock', 'absent', exitCode: 1), isNull);
      expect(await probe('', 'absent'), isNull);
      expect(await probe('6.12.69-stock', 'absent', complete: false), isNull);
      expect(await probe('6.12.69-stock', 'invalid'), isNull);
    },
  );
}
