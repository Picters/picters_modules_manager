import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/tx_profiles.dart';

void main() {
  group('txProfileFor — golden standards', () {
    void expectProfile(String text, String chip, int rec, int danger, int max) {
      final p = txProfileFor(text);
      expect(p.chip, chip, reason: '$text → chip');
      expect(p.recommended, rec, reason: '$text → recommended');
      expect(p.danger, danger, reason: '$text → danger');
      expect(p.max, max, reason: '$text → max');
    }

    test('resolves each chipset by label or driver name', () {
      expectProfile('TP-Link RTL8812AU', 'RTL8812AU', 24, 26, 30);
      expectProfile('Alfa AWUS1900 RTL8814AU', 'RTL8814AU', 24, 27, 33);
      expectProfile('D-Link DWA-182 RTL8822BU', 'RTL8812BU', 23, 25, 30);
      expectProfile('Realtek RTL8811AU', 'RTL8811AU', 18, 20, 22);
      expectProfile('Realtek RTL8188EUS', 'RTL8188EUS', 18, 20, 20);
    });

    test('resolves from bare driver (.ko) names', () {
      expect(txProfileFor('8814au').chip, 'RTL8814AU');
      expect(txProfileFor('88x2bu').chip, 'RTL8812BU');
      expect(txProfileFor('8188eu').chip, 'RTL8188EUS');
      // the aircrack 88XXau driver with no chip hint → the classic 8812AU
      expect(txProfileFor('88XXau').chip, 'RTL8812AU');
    });

    test('8814 beats 8812; 8812BU beats 8812AU (most-specific first)', () {
      expect(txProfileFor('RTL8814AU').chip, 'RTL8814AU');
      expect(txProfileFor('RTL8812BU').chip, 'RTL8812BU');
      expect(txProfileFor('RTL8812AU').chip, 'RTL8812AU');
    });

    test('unknown text falls back to a conservative generic profile', () {
      final p = txProfileFor('Some Unknown Dongle');
      expect(p.chip, 'Adapter');
      expect(p.recommended, 20);
      expect(p.max, 30);
    });

    test('recommended never exceeds max, danger sits between them', () {
      for (final t in [
        'RTL8811AU',
        'RTL8812AU',
        'RTL8812BU',
        'RTL8814AU',
        'RTL88x2EU',
        'RTL8188EUS',
        'unknown',
      ]) {
        final p = txProfileFor(t);
        expect(p.recommended, lessThanOrEqualTo(p.max), reason: t);
        expect(p.danger, lessThanOrEqualTo(p.max), reason: t);
        expect(p.recommended, lessThanOrEqualTo(p.danger), reason: t);
      }
    });
  });
}
