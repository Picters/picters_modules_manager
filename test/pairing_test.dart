import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/module_info.dart';
import 'package:picters_modules_manager/overview_screen.dart';
import 'package:picters_modules_manager/pending_op.dart';
import 'package:picters_modules_manager/usb_devices.dart';

DetectedAdapter _adapter({
  required String sysfs,
  String driver = 'rtl88XXau',
  String pid = '8812',
}) =>
    DetectedAdapter(
      device: UsbDevice(
        vendorId: '0bda',
        productId: pid,
        manufacturer: 'Realtek',
        product: '802.11n NIC',
        driver: driver,
        sysfsName: sysfs,
      ),
      match: const KnownAdapter('0bda', '8812', 'RTL8812AU', '88XXau'),
    );

WifiInterface _iface(String name, {String usb = '', String driver = 'rtl88XXau', bool up = true}) =>
    WifiInterface(name: name, driver: driver, up: up, monitor: false, usbPath: usb);

void main() {
  group('resolveAdapterInterfaces', () {
    test('two identical sticks get their own interface, not the same one', () {
      // The reported bug: same model, same driver — both rows showed wlan0, so
      // downing one appeared to down the other.
      final adapters = [_adapter(sysfs: '1-1.2'), _adapter(sysfs: '1-1.3')];
      final ifaces = [
        _iface('wlan0', usb: '1-1.2'),
        _iface('wlan1', usb: '1-1.3'),
      ];
      final out = resolveAdapterInterfaces(adapters, ifaces);
      expect(out[0]!.name, 'wlan0');
      expect(out[1]!.name, 'wlan1');
    });

    test('pairs by USB port, not by list order', () {
      final adapters = [_adapter(sysfs: '1-1.3'), _adapter(sysfs: '1-1.2')];
      final ifaces = [
        _iface('wlan0', usb: '1-1.2'),
        _iface('wlan1', usb: '1-1.3'),
      ];
      final out = resolveAdapterInterfaces(adapters, ifaces);
      expect(out[0]!.name, 'wlan1'); // the 1-1.3 adapter
      expect(out[1]!.name, 'wlan0');
    });

    test('without usb paths it still refuses to hand one iface to both', () {
      final adapters = [_adapter(sysfs: ''), _adapter(sysfs: '')];
      final ifaces = [_iface('wlan0'), _iface('wlan1')];
      final out = resolveAdapterInterfaces(adapters, ifaces);
      expect(out[0]!.name, isNot(out[1]!.name));
    });

    test('a second adapter with no interface of its own gets null', () {
      final adapters = [_adapter(sysfs: '1-1.2'), _adapter(sysfs: '1-1.3')];
      final out = resolveAdapterInterfaces(adapters, [_iface('wlan0', usb: '1-1.2')]);
      expect(out[0]!.name, 'wlan0');
      expect(out[1], isNull);
    });

    test('a different-driver adapter is not paired with a foreign interface', () {
      final adapters = [_adapter(sysfs: '', driver: '8188eu')];
      final out = resolveAdapterInterfaces(adapters, [_iface('wlan0')]);
      expect(out.single, isNull);
    });

    test('no interfaces at all yields nulls rather than throwing', () {
      final out = resolveAdapterInterfaces([_adapter(sysfs: '1-1.2')], const []);
      expect(out.single, isNull);
    });
  });

  _namingTests();

  group('PendingOp encode/decode', () {
    test('round-trips every field', () {
      final op = PendingOp(
        kind: PendingKind.reconfigure,
        target: 'wlan1',
        startedAt: DateTime.fromMillisecondsSinceEpoch(1770000000000),
        timeout: const Duration(seconds: 60),
      );
      final back = PendingOp.decode(op.encode())!;
      expect(back.kind, PendingKind.reconfigure);
      expect(back.target, 'wlan1');
      expect(back.startedAt, op.startedAt);
      expect(back.timeout, const Duration(seconds: 60));
    });

    test('a truncated or junk marker decodes to null, never a phantom spinner', () {
      expect(PendingOp.decode(''), isNull);
      expect(PendingOp.decode('reconfigure|wlan0'), isNull);
      expect(PendingOp.decode('notAKind|x|1|2'), isNull);
      expect(PendingOp.decode('reconfigure|x|notanumber|2'), isNull);
    });

    test('expiry is measured from the start plus the timeout', () {
      final start = DateTime(2026, 1, 1, 12);
      final op = PendingOp(
        kind: PendingKind.wifiInject,
        target: '',
        startedAt: start,
        timeout: const Duration(seconds: 90),
      );
      expect(op.expiredAt(start.add(const Duration(seconds: 89))), isFalse);
      expect(op.expiredAt(start.add(const Duration(seconds: 91))), isTrue);
    });
  });

  group('PendingOp.isSatisfiedBy', () {
    SystemState stateWith({
      WifiMode mode = WifiMode.inject,
      List<ModuleInfo> modules = const [],
      List<WifiInterface> interfaces = const [],
    }) =>
        SystemState(
          modules: modules,
          adapters: const [],
          interfaces: interfaces,
          wifiMode: mode,
          cfgLoaded: true,
          macLoaded: true,
          vendorWifiLoaded: false,
          modulesDirExists: true,
        );

    PendingOp op(PendingKind k, [String target = '']) => PendingOp(
          kind: k,
          target: target,
          startedAt: DateTime(2026),
          timeout: const Duration(seconds: 60),
        );

    test('a wifi switch is satisfied only by the mode it asked for', () {
      expect(op(PendingKind.wifiInject).isSatisfiedBy(stateWith()), isTrue);
      expect(
          op(PendingKind.wifiStock).isSatisfiedBy(stateWith()), isFalse);
      expect(
          op(PendingKind.wifiStock)
              .isSatisfiedBy(stateWith(mode: WifiMode.stock)),
          isTrue);
    });

    test('a module load waits for the module to actually be resident', () {
      const m = ModuleInfo(name: '88XXau', loaded: false, isWifiClass: true);
      expect(
          op(PendingKind.moduleLoad, '88XXau')
              .isSatisfiedBy(stateWith(modules: const [m])),
          isFalse);
      expect(
          op(PendingKind.moduleLoad, '88XXau').isSatisfiedBy(stateWith(
              modules: const [
                ModuleInfo(name: '88XXau', loaded: true, isWifiClass: true)
              ])),
          isTrue);
    });

    test('an unload counts a module that vanished entirely as done', () {
      expect(op(PendingKind.moduleUnload, '88XXau').isSatisfiedBy(stateWith()),
          isTrue);
    });

    test('reconfigure needs the iface up and out of monitor mode', () {
      expect(
          op(PendingKind.reconfigure, 'wlan1').isSatisfiedBy(stateWith(
              interfaces: [_iface('wlan1', up: false)])),
          isFalse);
      expect(
          op(PendingKind.reconfigure, 'wlan1')
              .isSatisfiedBy(stateWith(interfaces: [_iface('wlan1')])),
          isTrue);
    });

    test('reconfigure accepts the rename to wlan0 it may perform', () {
      expect(
          op(PendingKind.reconfigure, 'wlan1')
              .isSatisfiedBy(stateWith(interfaces: [_iface('wlan0')])),
          isTrue);
    });
  });
}

void _namingTests() {
  DetectedAdapter withMatch(KnownAdapter? m, {String product = '802.11n NIC'}) =>
      DetectedAdapter(
        device: UsbDevice(
          vendorId: '0bda',
          productId: '8812',
          manufacturer: 'Realtek',
          product: product,
          driver: 'rtl88XXau',
        ),
        match: m,
      );

  WifiInterface ifaceMac(String mac) => WifiInterface(
      name: 'wlan0', driver: 'rtl88XXau', up: true, monitor: false, mac: mac);

  group('vendorFromMac', () {
    test('names an Alfa by its OUI', () {
      expect(vendorFromMac('00:c0:ca:1a:2b:3c'), 'ALFA');
      expect(vendorFromMac('00:C0:CA:1A:2B:3C'), 'ALFA'); // case-insensitive
    });

    test('an unknown or malformed prefix names nobody', () {
      expect(vendorFromMac('aa:bb:cc:dd:ee:ff'), isNull);
      expect(vendorFromMac(''), isNull);
      expect(vendorFromMac('00:c0'), isNull);
    });
  });

  group('adapterTitle', () {
    const generic =
        KnownAdapter('0bda', '8812', 'Realtek RTL8812AU (default)', '88XXau');
    const branded =
        KnownAdapter('2357', '0115', 'TP-Link Archer T4U V3', '88x2bu');

    test('a real product name from the ID table wins outright', () {
      expect(adapterTitle(withMatch(branded), ifaceMac('00:c0:ca:1:2:3')),
          'TP-Link Archer T4U V3');
    });

    test('an Alfa on generic Realtek IDs is named from its MAC', () {
      // The whole point: VID:PID says "Realtek (default)", the OUI says ALFA.
      expect(adapterTitle(withMatch(generic), ifaceMac('00:c0:ca:1:2:3')),
          'ALFA RTL8812AU');
    });

    test('an unbranded stick falls back to naming the chipset', () {
      expect(adapterTitle(withMatch(generic), ifaceMac('00:e0:4c:1:2:3')),
          'RTL8812AU');
    });

    test('no interface yet still names the chipset from the ID table', () {
      expect(adapterTitle(withMatch(generic), null), 'RTL8812AU');
    });

    test('never invents a model — brand plus chipset is the ceiling', () {
      final t = adapterTitle(withMatch(generic), ifaceMac('00:c0:ca:1:2:3'));
      expect(t, isNot(contains('AWUS')));
    });
  });
}
