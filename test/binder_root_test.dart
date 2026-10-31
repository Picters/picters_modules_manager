import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/binder_root.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'accepted command errors are returned without requesting fallback replay',
    () async {
      const method = MethodChannel('com.picters.modulesmanager/system');
      const events = EventChannel(
        'com.picters.modulesmanager/system/root_events',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      late MockStreamHandlerEventSink sink;
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (_, output) {
            sink = output;
          },
        ),
      );
      var executions = 0;
      messenger.setMockMethodCallHandler(method, (call) async {
        if (call.method == 'bindRoot') return true;
        if (call.method == 'execRoot') {
          executions++;
          final id = (call.arguments as Map)['id'];
          Future<void>.delayed(Duration.zero, () {
            sink.success({'id': id, 'err': 'root command output failed'});
          });
          return true;
        }
        return null;
      });
      final binder = BinderRoot.instance;
      expect(await binder.tryBind(), isTrue);
      final result = await binder.exec('echo test', const Duration(seconds: 1));
      expect(result.ok, isFalse);
      expect(result.stdout, contains('root command output failed'));
      expect(executions, 1);
    },
  );
}
