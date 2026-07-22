/// Per-chipset tx-power "golden standards" for pentesting Realtek adapters —
/// loud but stable, never past what the chip's PA can physically do.
///
/// Values (dBm):
///  chip          recommended(safe max)   warns above   physical max
///  RTL8811/8821AU        18                  20             22
///  RTL8812AU             24                  26             30
///  RTL8812BU             23                  25             30
///  RTL8814AU             24                  27             33
///  RTL88x2EU             22                  24             30
///  RTL8188EUS            18                  20             20   (2.4-only micro)
///  (unknown)             20                  24             30   (conservative)
library;

/// Tx-power envelope for one chipset. [recommended] is the loud-but-stable
/// target; the UI warns once the value exceeds [danger]; the slider never goes
/// above [max] (the chip's physical ceiling).
class TxPowerProfile {
  const TxPowerProfile(this.chip, this.recommended, this.danger, this.max);

  final String chip;
  final int recommended;
  final int danger;
  final int max;
}

const TxPowerProfile _generic = TxPowerProfile('Adapter', 20, 24, 30);

/// Resolves the chipset profile from any free text that might name it — the
/// USB adapter's product label ("TP-Link RTL8812AU"), its bound driver name
/// ("88x2bu"/"88XXau"/"8814au"/"8188eu"), or a sysfs variant ("rtl88x2bu").
/// Most-specific chips are matched first (8814 before 8812, 8812BU before
/// 8812AU) so a shared driver name resolves to the right envelope.
TxPowerProfile txProfileFor(String text) {
  final s = text.toUpperCase();
  bool has(String p) => s.contains(p);

  if (has('8814')) return const TxPowerProfile('RTL8814AU', 24, 27, 33);
  if (has('8812BU') || has('8822BU') || has('88X2BU')) {
    return const TxPowerProfile('RTL8812BU', 23, 25, 30);
  }
  if (has('88X2EU') || has('8822EU')) {
    return const TxPowerProfile('RTL88x2EU', 22, 24, 30);
  }
  // RTL8811AU / RTL8821AU are the low-power 1x1 sticks — grouped together.
  if (has('8811') || has('8821')) {
    return const TxPowerProfile('RTL8811AU', 18, 20, 22);
  }
  if (has('8812')) {
    return const TxPowerProfile('RTL8812AU', 24, 26, 30);
  }
  if (has('8188')) return const TxPowerProfile('RTL8188EUS', 18, 20, 20);
  // The aircrack "88XXau" driver with no chip hint → assume the classic 8812AU.
  if (has('88XXAU')) return const TxPowerProfile('RTL8812AU', 24, 26, 30);
  return _generic;
}
