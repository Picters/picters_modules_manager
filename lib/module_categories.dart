/// Categorizes the non-Wi-Fi "other drivers" for the Modules screen.
/// Sourced directly from android_kernel_xiaomi_sm8850's
/// arch/arm64/configs/extra_modules.list (the actual whitelist the kernel
/// CI packages), not guessed from module names.
enum ModuleCategory {
  bluetooth('Bluetooth'),
  can('CAN'),
  sdr('SDR / DVB'),
  usbSerial('USB Serial'),
  usbEthernet('USB Ethernet'),
  netfilter('Netfilter'),
  filesystem('Filesystem'),
  other('Other');

  const ModuleCategory(this.label);
  final String label;
}

const Map<String, ModuleCategory> _categoryByModule = {
  // --- Bluetooth ---
  'btusb': ModuleCategory.bluetooth,
  'btbcm': ModuleCategory.bluetooth,
  'btrtl': ModuleCategory.bluetooth,
  'btintel': ModuleCategory.bluetooth,
  'hci_uart': ModuleCategory.bluetooth,
  'bcm203x': ModuleCategory.bluetooth,
  'bpa10x': ModuleCategory.bluetooth,
  'bfusb': ModuleCategory.bluetooth,
  'hci_vhci': ModuleCategory.bluetooth,
  'rfcomm': ModuleCategory.bluetooth,
  'bnep': ModuleCategory.bluetooth,
  'hidp': ModuleCategory.bluetooth,

  // --- CAN / CARsenal ---
  'can': ModuleCategory.can,
  'can-raw': ModuleCategory.can,
  'can-bcm': ModuleCategory.can,
  'can-gw': ModuleCategory.can,
  'can-dev': ModuleCategory.can,
  'vcan': ModuleCategory.can,
  'slcan': ModuleCategory.can,
  'hi311x': ModuleCategory.can,
  'mcp251x': ModuleCategory.can,
  'ems_usb': ModuleCategory.can,
  'esd_usb': ModuleCategory.can,
  'gs_usb': ModuleCategory.can,
  'kvaser_usb': ModuleCategory.can,
  'peak_usb': ModuleCategory.can,
  'usb_8dev': ModuleCategory.can,
  'netlink_diag': ModuleCategory.can,

  // --- SDR / DVB ---
  'i2c-mux': ModuleCategory.sdr,
  'dvb-core': ModuleCategory.sdr,
  'dvb_usb_v2': ModuleCategory.sdr,
  'dvb-usb-rtl28xxu': ModuleCategory.sdr,
  'rtl2830': ModuleCategory.sdr,
  'rtl2832': ModuleCategory.sdr,
  'rtl2832_sdr': ModuleCategory.sdr,
  'si2168': ModuleCategory.sdr,
  'zd1301_demod': ModuleCategory.sdr,
  'r820t': ModuleCategory.sdr,
  'e4000': ModuleCategory.sdr,
  'fc0011': ModuleCategory.sdr,
  'fc0012': ModuleCategory.sdr,
  'fc0013': ModuleCategory.sdr,

  // --- USB serial ---
  'usbserial': ModuleCategory.usbSerial,
  'ch341': ModuleCategory.usbSerial,
  'cp210x': ModuleCategory.usbSerial,
  'ftdi_sio': ModuleCategory.usbSerial,
  'pl2303': ModuleCategory.usbSerial,

  // --- USB Ethernet ---
  'rtl8150': ModuleCategory.usbEthernet,
  'r8152': ModuleCategory.usbEthernet,
  'cdc_ether': ModuleCategory.usbEthernet,
  'cdc_subset': ModuleCategory.usbEthernet,
  'rndis_host': ModuleCategory.usbEthernet,

  // --- Netfilter / bridged MITM ---
  'nf_tables': ModuleCategory.netfilter,
  'nft_compat': ModuleCategory.netfilter,
  'br_netfilter': ModuleCategory.netfilter,
  'ebtables': ModuleCategory.netfilter,
  'ebtable_broute': ModuleCategory.netfilter,
  'ebtable_filter': ModuleCategory.netfilter,
  'ebtable_nat': ModuleCategory.netfilter,

  // --- Filesystems ---
  'ntfs3': ModuleCategory.filesystem,
};

ModuleCategory categoryOf(String moduleName) =>
    _categoryByModule[moduleName] ?? ModuleCategory.other;

/// Human-readable one-liners for the modules worth explaining — the Wi-Fi
/// stack and the adapter chipset drivers most users actually reach for. Others
/// fall back to just their filename; the category grouping already frames them.
const Map<String, String> _moduleDescriptions = {
  'cfg80211': 'Wireless configuration core',
  'mac80211': 'Soft-MAC 802.11 layer',
  '88XXau': 'Realtek RTL8812AU / 8821AU',
  '8188eu': 'Realtek RTL8188EUS',
  '8814au': 'Realtek RTL8814AU',
  '88x2bu': 'Realtek RTL8812BU / 8822BU',
  'rtl8xxxu': 'Realtek USB Wi-Fi (in-tree)',
  'mt7601u': 'MediaTek MT7601U',
  'carl9170': 'Atheros AR9170',
  'ath9k_htc': 'Atheros AR9271 / AR7010',
  'zd1211rw': 'ZyDAS ZD1211',
  'btusb': 'Bluetooth USB transport',
  'hci_uart': 'Bluetooth UART transport',
  'can': 'Controller Area Network core',
  'gs_usb': 'Geschwister Schneider USB/CAN',
  'ftdi_sio': 'FTDI USB serial',
  'cp210x': 'Silicon Labs CP210x serial',
  'ch341': 'WCH CH341 USB serial',
  'pl2303': 'Prolific PL2303 serial',
  'r8152': 'Realtek USB Gigabit Ethernet',
  'dvb_usb_v2': 'DVB-T / RTL-SDR core',
  'rtl2832': 'Realtek RTL2832U demod (SDR)',
  'nf_tables': 'nftables packet filtering',
  'ntfs3': 'NTFS read/write filesystem',
};

String? moduleDescription(String moduleName) => _moduleDescriptions[moduleName];

/// Display order — bigger/more common buckets first.
const List<ModuleCategory> categoryOrder = [
  ModuleCategory.bluetooth,
  ModuleCategory.can,
  ModuleCategory.sdr,
  ModuleCategory.usbSerial,
  ModuleCategory.usbEthernet,
  ModuleCategory.netfilter,
  ModuleCategory.filesystem,
  ModuleCategory.other,
];
