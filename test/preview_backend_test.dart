import 'package:flutter_test/flutter_test.dart';

import 'package:picters_modules_manager/module_info.dart';
import 'package:picters_modules_manager/native_bridge.dart';
import 'package:picters_modules_manager/perf_info.dart';
import 'package:picters_modules_manager/preview_backend.dart';
import 'package:picters_modules_manager/preview_environment.dart';
import 'package:picters_modules_manager/root_shell.dart';

void main() {
  test(
    'desktop preview blocks both root entry points and native storage',
    () async {
      expect(PreviewEnvironment.enabled, isTrue);
      expect(await RootShell.checkRoot(), isFalse);
      expect(await RootSession.instance.ensureStarted(), isFalse);
      final facade = await RootShell.run('echo must-not-run');
      final session = await RootSession.instance.run('echo must-not-run');
      expect(facade.ok, isFalse);
      expect(session.ok, isFalse);
      expect(facade.stdout, contains('disabled in preview'));
      expect(await NativeBridge.filesDir(), isNull);
      expect(await NativeBridge.usbEvents().toList(), isEmpty);
      expect(await NativeBridge.openUrl('file:///tmp/example'), isFalse);
      expect(
        await NativeBridge.openUrl('https://user:password@example.com'),
        isFalse,
      );
    },
  );

  test(
    'preview uses live controllers with independent in-memory actions',
    () async {
      final controller = createPreviewController();
      addTearDown(controller.dispose);
      await controller.init();
      await controller.perf.init();
      await controller.settings.init();

      expect(controller.isPreview, isTrue);
      expect(controller.rootStatus.name, 'granted');
      expect(controller.state.modulesDirExists, isTrue);
      expect(controller.perf.state.clusters[0].maxHardware, 3628800);
      expect(controller.perf.state.clusters[1].maxHardware, 4608000);
      expect(controller.perf.state.gamingSupported, isTrue);
      expect(controller.perf.state.frequencyLockSupported, isTrue);
      expect(controller.releases.newReleaseAvailable, isFalse);

      expect(await controller.setWifiMode(WifiMode.inject), isNull);
      final adapter = controller.state.adapters.first;
      expect(await controller.loadAdapter(adapter), isNull);
      expect(controller.state.interfaces.single.driver, '88XXau');

      await controller.perf.setProfile(PerfProfile.gaming);
      expect(controller.perf.state.gamingActive, isTrue);
      expect(controller.perf.state.frequenciesLocked, isFalse);
      await controller.perf.setFrequencyLock(true);
      expect(controller.perf.state.lockActive, isTrue);
      await controller.perf.setProfile(PerfProfile.full);
      expect(controller.perf.state.gamingActive, isFalse);
      expect(controller.perf.state.frequenciesLocked, isTrue);
      await controller.perf.setFrequencyLock(false);
      expect(controller.perf.state.lockActive, isFalse);

      expect(await controller.setWifiMode(WifiMode.stock), isNull);
      expect(controller.state.interfaces.single.driver, 'qca_cld3_peach_v2');
      await controller.settings.setBootLoadEnabled(false);
      expect(controller.settings.bootLoadEnabled, isFalse);
    },
  );
}
