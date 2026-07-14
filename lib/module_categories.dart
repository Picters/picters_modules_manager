/// Categorizes the non-Wi-Fi "other drivers" for the Modules screen.
/// Sourced directly from android_kernel_xiaomi_sm8850's
/// arch/arm64/configs/nethunter_modules.list (the actual whitelist the kernel
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
