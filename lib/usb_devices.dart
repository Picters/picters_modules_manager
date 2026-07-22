/// A USB device the kernel currently enumerates, read straight from sysfs.
class UsbDevice {
  const UsbDevice({
    required this.vendorId,
    required this.productId,
    required this.manufacturer,
    required this.product,
    this.deviceClass = '',
    this.driver = '',
  });

  /// Lowercase 4-hex-digit strings, e.g. "0bda" — as sysfs already reports them.
  final String vendorId;
  final String productId;
  final String manufacturer;
  final String product;

  /// `bDeviceClass` from sysfs, e.g. "e0" (wireless), "09" (hub), "00" (per
  /// interface). Used to guess the device kind when no driver is bound.
  final String deviceClass;

  /// The kernel driver currently bound to the device's first interface (e.g.
  /// "btusb", "cdc_acm", "88XXau"), or empty if nothing is bound — meaning the
  /// device is present but no driver in the running kernel claims it.
  final String driver;

  String get idPair => '$vendorId:$productId';

  String get displayName {
    final label = product.isNotEmpty ? product : manufacturer;
    return label.isNotEmpty ? label : 'USB device';
  }
}

/// Broad device families we can tell apart from the bound driver name or the
/// USB device class — just enough to give each row a recognisable icon.
enum UsbKind { wifi, bluetooth, can, serial, network, storage, hub, other }

/// Best-effort classification: the bound driver name is the most reliable
/// signal, then the recognised-Wi-Fi match, then the raw USB class code.
UsbKind classifyUsb(DetectedAdapter a) {
  final drv = a.device.driver.toLowerCase();
  if (drv.isNotEmpty) {
    if (drv == 'btusb' || drv.startsWith('bt')) return UsbKind.bluetooth;
    if (drv == 'gs_usb' ||
        drv.contains('peak_usb') ||
        drv.contains('kvaser') ||
        drv.contains('_can') ||
        drv.contains('mcba')) {
      return UsbKind.can;
    }
    if (drv.contains('cdc_acm') ||
        drv.contains('ftdi') ||
        drv.contains('cp210') ||
        drv.contains('ch34') ||
        drv.contains('pl2303') ||
        drv.contains('option') ||
        drv.contains('serial')) {
      return UsbKind.serial;
    }
    if (drv.contains('cdc_ether') ||
        drv.contains('cdc_ncm') ||
        drv.contains('rndis') ||
        drv.contains('r8152') ||
        drv.contains('ax88') ||
        drv.contains('asix')) {
      return UsbKind.network;
    }
    if (drv.contains('storage') || drv == 'uas') return UsbKind.storage;
    if (drv.contains('cfg80211') ||
        drv.contains('80211') ||
        drv.contains('wifi')) {
      return UsbKind.wifi;
    }
  }
  if (a.recognized) return UsbKind.wifi;
  switch (a.device.deviceClass) {
    case 'e0':
      return UsbKind.bluetooth;
    case '09':
      return UsbKind.hub;
    case '08':
      return UsbKind.storage;
    case '02':
    case '0a':
      return UsbKind.network;
  }
  return UsbKind.other;
}

/// A known Wi-Fi adapter chipset entry: which on-disk driver (.ko basename,
/// matching ModuleInfo.name) a given VID:PID needs.
class KnownAdapter {
  const KnownAdapter(this.vendorId, this.productId, this.label, this.driver);
  final String vendorId;
  final String productId;
  final String label;
  final String driver;
}

/// Sourced from the exact driver forks this project ships (see
/// Kokuban_Kernel_CI_Center/configs/projects.json `extra_oot_modules`):
/// aircrack-ng/rtl8812au, aircrack-ng/rtl8188eus, morrownr/8814au,
/// morrownr/88x2bu-20210702 — each repo's own `supported-device-IDs` file.
/// Default chipset IDs first, then the reseller-branded IDs from those files.
const List<KnownAdapter> kKnownAdapters = <KnownAdapter>[
  // RTL8812AU -> 88XXau
  KnownAdapter('0bda', '8812', 'Realtek RTL8812AU (default)', '88XXau'),
  KnownAdapter('0bda', '881a', 'Realtek RTL8812AU-VS (default)', '88XXau'),
  KnownAdapter('0bda', '881b', 'Realtek RTL8812AU-VL (default)', '88XXau'),
  KnownAdapter('0bda', '881c', 'Realtek RTL8812AU-VN (default)', '88XXau'),
  KnownAdapter('0409', '0408', 'NEC RTL8812AU', '88XXau'),
  KnownAdapter('0411', '025d', 'Buffalo RTL8812AU', '88XXau'),
  KnownAdapter('04bb', '0952', 'I-O DATA RTL8812AU', '88XXau'),
  KnownAdapter('050d', '1106', 'Belkin RTL8812AU', '88XXau'),
  KnownAdapter('050d', '1109', 'Belkin RTL8812AU', '88XXau'),
  KnownAdapter('0586', '3426', 'ZyXEL RTL8812AU', '88XXau'),
  KnownAdapter('0789', '016e', 'Logitec RTL8812AU', '88XXau'),
  KnownAdapter('07b8', '8812', 'Abocom RTL8812AU', '88XXau'),
  KnownAdapter('0846', '9051', 'Netgear RTL8812AU', '88XXau'),
  KnownAdapter('0b05', '17d2', 'ASUS RTL8812AU', '88XXau'),
  KnownAdapter('0df6', '0074', 'Sitecom RTL8812AU', '88XXau'),
  KnownAdapter('0e66', '0022', 'Hawking RTL8812AU', '88XXau'),
  KnownAdapter('1058', '0632', 'WD RTL8812AU', '88XXau'),
  KnownAdapter('13b1', '003f', 'Linksys RTL8812AU', '88XXau'),
  KnownAdapter('148f', '9097', 'Amped Wireless RTL8812AU', '88XXau'),
  KnownAdapter('1740', '0100', 'EnGenius RTL8812AU', '88XXau'),
  KnownAdapter('2001', '330e', 'D-Link RTL8812AU', '88XXau'),
  KnownAdapter('2001', '3313', 'D-Link RTL8812AU', '88XXau'),
  KnownAdapter('2001', '3315', 'D-Link RTL8812AU', '88XXau'),
  KnownAdapter('2001', '3316', 'D-Link RTL8812AU', '88XXau'),
  KnownAdapter('2019', 'ab30', 'Planex RTL8812AU', '88XXau'),
  KnownAdapter('20f4', '805b', 'TRENDnet RTL8812AU', '88XXau'),
  KnownAdapter('2357', '0101', 'TP-Link RTL8812AU', '88XXau'),
  KnownAdapter('2357', '0103', 'TP-Link RTL8812AU', '88XXau'),
  KnownAdapter('2357', '010d', 'TP-Link RTL8812AU', '88XXau'),
  KnownAdapter('2357', '010e', 'TP-Link RTL8812AU', '88XXau'),
  KnownAdapter('2357', '010f', 'TP-Link RTL8812AU', '88XXau'),
  KnownAdapter('2357', '0122', 'TP-Link RTL8812AU', '88XXau'),
  KnownAdapter('2604', '0012', 'Tenda RTL8812AU', '88XXau'),
  KnownAdapter('7392', 'a822', 'Edimax RTL8812AU', '88XXau'),

  // RTL8188EU -> 8188eu
  KnownAdapter('0bda', '8179', 'Realtek RTL8188EUS (default)', '8188eu'),

  // RTL8814AU -> 8814au
  KnownAdapter('0bda', '8813', 'Realtek RTL8814AU (default)', '8814au'),
  KnownAdapter('2001', '331a', 'D-Link RTL8814AU', '8814au'),
  KnownAdapter('0b05', '1817', 'ASUS RTL8814AU', '8814au'),
  KnownAdapter('0b05', '1852', 'ASUS RTL8814AU', '8814au'),
  KnownAdapter('0b05', '1853', 'ASUS RTL8814AU', '8814au'),
  KnownAdapter('056e', '400b', 'Elecom RTL8814AU', '8814au'),
  KnownAdapter('056e', '400d', 'Elecom RTL8814AU', '8814au'),
  KnownAdapter('7392', 'a834', 'Edimax RTL8814AU', '8814au'),
  KnownAdapter('7392', 'a833', 'Edimax RTL8814AU', '8814au'),
  KnownAdapter('0e66', '0026', 'Hawking RTL8814AU', '8814au'),
  KnownAdapter('2357', '0106', 'TP-Link RTL8814AU', '8814au'),
  KnownAdapter('20f4', '809a', 'TRENDnet RTL8814AU', '8814au'),
  KnownAdapter('20f4', '809b', 'TRENDnet RTL8814AU', '8814au'),
  KnownAdapter('0846', '9054', 'Netgear RTL8814AU', '8814au'),

  // RTL8812BU / RTL8822BU -> 88x2bu
  KnownAdapter('0bda', 'b812', 'Realtek RTL8812BU (default)', '88x2bu'),
  KnownAdapter('0bda', 'b81a', 'Realtek RTL8822BU (default)', '88x2bu'),
  KnownAdapter('0bda', 'b82c', 'Realtek RTL8822BU combo (default)', '88x2bu'),
  KnownAdapter('04ca', '8602', 'LiteOn RTL8822BU', '88x2bu'),
  KnownAdapter('056e', '4011', 'Elecom RTL8822BU', '88x2bu'),
  KnownAdapter('0846', '9055', 'Netgear A6150', '88x2bu'),
  KnownAdapter('0b05', '1841', 'ASUS USB-AC55 B1', '88x2bu'),
  KnownAdapter('0b05', '184c', 'ASUS RTL8822BU', '88x2bu'),
  KnownAdapter('0b05', '1870', 'ASUS RTL8822BU', '88x2bu'),
  KnownAdapter('0b05', '1874', 'ASUS RTL8822BU', '88x2bu'),
  KnownAdapter('0b05', '19aa', 'ASUS USB-AC58 rev A1', '88x2bu'),
  KnownAdapter('0bda', '2102', 'CCNC RTL8822BU', '88x2bu'),
  KnownAdapter('0e66', '0025', 'Hawking HW12ACU', '88x2bu'),
  KnownAdapter('13b1', '0043', 'Linksys RTL8822BU', '88x2bu'),
  KnownAdapter('13b1', '0045', 'Linksys WUSB3600 v2', '88x2bu'),
  KnownAdapter('2001', '331e', 'D-Link DWA-182', '88x2bu'),
  KnownAdapter('2001', '331c', 'D-Link DWA-181', '88x2bu'),
  KnownAdapter('2001', '331f', 'D-Link DWA-183', '88x2bu'),
  KnownAdapter('20f4', '805a', 'TRENDnet TEW-805UBH', '88x2bu'),
  KnownAdapter('20f4', '808a', 'TRENDnet TEW-808UBM', '88x2bu'),
  KnownAdapter('2357', '0115', 'TP-Link Archer T4U V3', '88x2bu'),
  KnownAdapter('2357', '0116', 'TP-Link RTL8822BU', '88x2bu'),
  KnownAdapter('2357', '0117', 'TP-Link RTL8822BU', '88x2bu'),
  KnownAdapter('2357', '012d', 'TP-Link Archer T3U v1', '88x2bu'),
  KnownAdapter('2357', '012e', 'TP-Link RTL8822BU', '88x2bu'),
  KnownAdapter('2357', '0138', 'TP-Link Archer T3U Plus v1', '88x2bu'),
  KnownAdapter('2c4e', '0107', 'Mercusys MA30H', '88x2bu'),
  KnownAdapter('7392', 'b822', 'Edimax RTL8822BU', '88x2bu'),
  KnownAdapter('7392', 'c822', 'Edimax RTL8822BU', '88x2bu'),
  KnownAdapter('7392', 'd822', 'Edimax RTL8822BU', '88x2bu'),
  KnownAdapter('7392', 'e822', 'Edimax RTL8822BU', '88x2bu'),
  KnownAdapter('7392', 'f822', 'Edimax RTL8822BU', '88x2bu'),
];

/// One attached device matched (or not) against [kKnownAdapters].
class DetectedAdapter {
  const DetectedAdapter({required this.device, required this.match});
  final UsbDevice device;
  final KnownAdapter? match;

  bool get recognized => match != null;
}

/// Shell fragment that lists every USB device's VID:PID/manufacturer/product,
/// one per line, each prefixed with [usbMarker]. Root-only because sysfs
/// listing isn't world-readable under some SELinux policies. Folded into the
/// single combined scan in ModuleRepository so a 1s poll is one `su` round-trip.
const String usbMarker = '___PMM_USB___';

const String usbScanFragment =
    'for d in /sys/bus/usb/devices/*/; do '
    'if [ -f "\${d}idVendor" ] && [ -f "\${d}idProduct" ]; then '
    'drv=""; '
    'for i in "\${d}"*:*/; do '
    'if [ -L "\${i}driver" ]; then drv=\$(basename "\$(readlink "\${i}driver")"); break; fi; '
    'done; '
    'echo "$usbMarker\$(cat "\${d}idVendor" 2>/dev/null)|\$(cat "\${d}idProduct" 2>/dev/null)|\$(cat "\${d}manufacturer" 2>/dev/null)|\$(cat "\${d}product" 2>/dev/null)|\$(cat "\${d}bDeviceClass" 2>/dev/null)|\${drv}"; '
    'fi; done';

/// Shell fragment that lists every live wireless netdev (a `phy80211` dir under
/// it) as `name|driver|flags|type`, one per line, each prefixed with
/// [ifaceMarker]. `flags` is the hex IFF_* bitmask (`/sys/class/net/*/flags`);
/// bit 0 (IFF_UP) is the *admin* up/down the toggle drives — read here instead
/// of `operstate`, which reads "unknown"/"down" for a monitor VIF or an
/// unassociated managed iface even while it's admin-up. `type` is the ARPHRD
/// number (1 = ether/managed, 803 = radiotap/monitor). Folded into the same
/// combined scan as [usbScanFragment].
const String ifaceMarker = '___PMM_IFACE___';

const String ifaceScanFragment =
    'for n in /sys/class/net/*/; do '
    '[ -d "\${n}phy80211" ] || continue; '
    'ifn=\$(basename "\$n"); '
    'drv=""; '
    'if [ -L "\${n}device/driver" ]; then drv=\$(basename "\$(readlink "\${n}device/driver")"); fi; '
    'echo "$ifaceMarker\${ifn}|\${drv}|\$(cat "\${n}flags" 2>/dev/null)|\$(cat "\${n}type" 2>/dev/null)"; '
    'done';

/// Parses the lines produced by [usbScanFragment] (already split on '\n') into
/// matched [DetectedAdapter]s.
List<DetectedAdapter> parseUsbLines(Iterable<String> lines) {
  final out = <DetectedAdapter>[];
  for (final line in lines) {
    final idx = line.indexOf(usbMarker);
    if (idx < 0) continue;
    final fields = line.substring(idx + usbMarker.length).split('|');
    if (fields.length < 2) continue;
    final vid = fields[0].trim().toLowerCase();
    final pid = fields[1].trim().toLowerCase();
    if (vid.isEmpty || pid.isEmpty) continue;
    final device = UsbDevice(
      vendorId: vid,
      productId: pid,
      manufacturer: fields.length > 2 ? fields[2].trim() : '',
      product: fields.length > 3 ? fields[3].trim() : '',
      deviceClass: fields.length > 4 ? fields[4].trim().toLowerCase() : '',
      driver: fields.length > 5 ? fields[5].trim() : '',
    );
    KnownAdapter? match;
    for (final k in kKnownAdapters) {
      if (k.vendorId == vid && k.productId == pid) {
        match = k;
        break;
      }
    }
    out.add(DetectedAdapter(device: device, match: match));
  }
  return out;
}
