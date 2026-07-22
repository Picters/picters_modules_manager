import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/iw_repository.dart';
import 'package:picters_modules_manager/root_shell.dart';

/// A [RootRunner] that records every script it's handed and replies with a
/// canned [ShellResult] — mirrors the fake used by the other repository tests,
/// so we can assert on the exact shell IwRepository emits with no device or
/// Flutter asset-bundle binding needed.
class FakeRootRunner implements RootRunner {
  FakeRootRunner([this.responder]);

  final ShellResult Function(String script)? responder;
  final List<String> scripts = [];
  String get lastScript => scripts.last;

  @override
  Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    scripts.add(script);
    return responder?.call(script) ?? const ShellResult(0, '');
  }
}

void main() {
  group('script builders', () {
    test('setMode brackets the type change with link down/up', () {
      final s = iwSetModeScript('/data/x/iw', 'wlan0', true);
      expect(s, contains("ip link set 'wlan0' down"));
      expect(s, contains("'/data/x/iw' dev 'wlan0' set type monitor"));
      expect(s, contains("ip link set 'wlan0' up"));
      expect(s, contains('OK_MODE'));
    });

    test('setMode targets managed when monitor is false', () {
      expect(iwSetModeScript('/x/iw', 'wlan1', false),
          contains('set type managed'));
    });

    test('setLinkScript needs no iw binary at all', () {
      expect(iwSetLinkScript('wlan0', true), contains("ip link set 'wlan0' up"));
      expect(
          iwSetLinkScript('wlan0', false), contains("ip link set 'wlan0' down"));
    });

    test('setRegDomainScript stages the db, reloads, then sets the domain', () {
      final s = iwSetRegDomainScript('/x/iw', 'BO', '/files/regulatory.db');
      // Places the bundled db into the kernel firmware path,
      expect(s, contains("cp '/files/regulatory.db' '$kRegDbPath'"));
      // reloads cfg80211's regdb (clears any cached boot-time load error),
      expect(s, contains("'/x/iw' reg reload"));
      // then applies the domain.
      expect(s, contains("'/x/iw' reg set BO"));
      expect(s, contains('OK_REG'));
      // reload must come before set.
      expect(s.indexOf('reg reload'), lessThan(s.indexOf('reg set BO')));
    });

    test('setTxPowerScript converts dBm to mBm', () {
      final s = iwSetTxPowerScript('/x/iw', 'wlan0', 24);
      expect(s, contains('set txpower fixed 2400'));
      expect(s, contains('OK_TXPOWER'));
    });
  });

  group('parsing', () {
    test('parseTxPowerDbm reads the txpower line from `iw dev info`', () {
      const out = '''
Interface wlan0
	ifindex 44
	type managed
	txpower 20.00 dBm''';
      expect(parseTxPowerDbm(out), 20.0);
    });

    test('parseTxPowerDbm is null when no txpower line is present', () {
      expect(parseTxPowerDbm('Interface wlan0\n\ttype managed'), isNull);
    });

    test('parseWiphyIndex reads the "wiphy N" line from `iw dev info`', () {
      const out = 'Interface wlan1\n\tifindex 44\n\twiphy 1\n\ttype managed';
      expect(parseWiphyIndex(out), 1);
    });

    // Real `iw reg get` output only ever lists a phy-specific block for a
    // self-managed wiphy (the built-in chip here, phy#0) — a plain radio like
    // a USB adapter's phy#1 has no block of its own and just follows global.
    const regOut = '''
global
country 00: DFS-UNSET
	(...)
phy#0 (self-managed)
country RU: DFS-UNSET
	(...)''';

    test('parseRegDomainForPhy matches a USB adapter (phy#1, unlisted) to the '
        'global domain, not the self-managed built-in phy#0', () {
      // The old "just take the last country line" approach would have wrongly
      // reported the self-managed phy#0's RU here instead of the global one
      // that actually governs an unrelated, non-self-managed radio.
      final r = parseRegDomainForPhy(regOut, 1);
      expect(r.domain, '00');
      expect(r.selfManaged, isFalse);
    });

    test('parseRegDomainForPhy reports the self-managed phy\'s own domain '
        'and flags it as locked', () {
      final r = parseRegDomainForPhy(regOut, 0);
      expect(r.domain, 'RU');
      expect(r.selfManaged, isTrue);
    });

    test('parseRegDomainForPhy falls back to global when wiphy is unknown',
        () {
      final r = parseRegDomainForPhy(regOut, null);
      expect(r.domain, '00');
      expect(r.selfManaged, isFalse);
    });

    test('parseIwQuery splits the info/reg sections and matches by wiphy', () {
      const out = 'Interface wlan0\n\twiphy 0\n\ttxpower 20.00 dBm\n'
          '__IW_REG__\n$regOut';
      final info = parseIwQuery(out);
      expect(info.txPowerDbm, 20.0);
      expect(info.regDomain, 'RU');
      expect(info.regDomainLocked, isTrue);
    });

    test('parseIwQuery for a non-self-managed radio reports global + unlocked',
        () {
      const out = 'Interface wlan1\n\twiphy 1\n\ttxpower 27.00 dBm\n'
          '__IW_REG__\n$regOut';
      final info = parseIwQuery(out);
      expect(info.regDomain, '00');
      expect(info.regDomainLocked, isFalse);
    });
  });

  group('IwRepository', () {
    test('ensureBinary chmods the resolved path once and caches it', () async {
      final shell = FakeRootRunner();
      var resolverCalls = 0;
      final repo = IwRepository(shell, () async {
        resolverCalls++;
        return '/data/user/0/app/files/iw';
      });

      final p1 = await repo.ensureBinary();
      final p2 = await repo.ensureBinary();

      expect(p1, '/data/user/0/app/files/iw');
      expect(p2, p1);
      expect(resolverCalls, 1); // cached after the first call
      expect(shell.scripts, hasLength(1));
      expect(shell.lastScript, contains("chmod 755 '/data/user/0/app/files/iw'"));
    });

    test('setMode emits the bracketed script against the resolved binary',
        () async {
      final shell = FakeRootRunner((s) => const ShellResult(0, 'OK_MODE'));
      final repo = IwRepository(shell, () async => '/bin/iw');

      final r = await repo.setMode(iface: 'wlan0', monitor: true);

      expect(r.stdout, contains('OK_MODE'));
      expect(shell.scripts.last, contains("'/bin/iw' dev 'wlan0' set type monitor"));
    });

    test('setRegulatoryDomain stages the resolved db then reloads+sets',
        () async {
      final shell = FakeRootRunner((s) => const ShellResult(0, 'OK_REG'));
      final repo = IwRepository(
        shell,
        () async => '/bin/iw',
        () async => '/files/regulatory.db',
      );

      final r = await repo.setRegulatoryDomain('BO');

      expect(r.stdout, contains('OK_REG'));
      expect(shell.scripts.last, contains("cp '/files/regulatory.db'"));
      expect(shell.scripts.last, contains("'/bin/iw' reg reload"));
      expect(shell.scripts.last, contains("'/bin/iw' reg set BO"));
    });

    test('setRegulatoryDomain fails cleanly when the db cannot be staged',
        () async {
      final shell = FakeRootRunner();
      final repo = IwRepository(
        shell,
        () async => '/bin/iw',
        () async => null, // regulatory.db not extractable
      );

      final r = await repo.setRegulatoryDomain('BO');

      expect(r.ok, isFalse);
      // ensureBinary chmod ran, but no reg-set script was emitted.
      expect(shell.scripts.any((s) => s.contains('reg set')), isFalse);
    });

    test('setLinkUp never touches ensureBinary (no iw dependency)', () async {
      final shell = FakeRootRunner((s) => const ShellResult(0, 'OK_LINK'));
      var resolverCalls = 0;
      final repo = IwRepository(shell, () async {
        resolverCalls++;
        return '/bin/iw';
      });

      await repo.setLinkUp(iface: 'wlan0', up: false);

      expect(resolverCalls, 0);
      expect(shell.scripts, hasLength(1));
      expect(shell.lastScript, contains("ip link set 'wlan0' down"));
    });

    test('query combines info+reg and parses the reply', () async {
      final shell = FakeRootRunner((s) => const ShellResult(
            0,
            'Interface wlan0\n\ttxpower 24.00 dBm\n'
                '__IW_REG__\nglobal\ncountry BO: DFS-UNSET',
          ));
      final repo = IwRepository(shell, () async => '/bin/iw');

      final info = await repo.query('wlan0');

      expect(info, isNotNull);
      expect(info!.txPowerDbm, 24.0);
      expect(info.regDomain, 'BO');
    });

    test('actions report unavailable when the binary cannot be resolved',
        () async {
      final shell = FakeRootRunner();
      final repo = IwRepository(shell, () async => null);

      final r = await repo.setTxPower(iface: 'wlan0', dbm: 24);

      expect(r.ok, isFalse);
      expect(shell.scripts, isEmpty); // never even tried to chmod/run
    });
  });
}
