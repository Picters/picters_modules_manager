import 'package:flutter/material.dart';

import 'charging_power_card.dart';
import 'device_controls.dart';
import 'thermal_control_card.dart';

/// Both controls observe one applied state, including shared reboot persistence.
class DeviceControlCards extends StatefulWidget {
  const DeviceControlCards({
    super.key,
    this.preview = false,
    this.persistOnBoot = false,
  });
  final bool preview;
  final bool persistOnBoot;

  @override
  State<DeviceControlCards> createState() => _DeviceControlCardsState();
}

class _DeviceControlCardsState extends State<DeviceControlCards> {
  late final _controls = DeviceControlsController(preview: widget.preview);

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _controls.init();
    if (mounted) await _controls.setBootPersistence(widget.persistOnBoot);
  }

  @override
  void dispose() {
    _controls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ThermalControlCard(
        preview: widget.preview,
        persistOnBoot: widget.persistOnBoot,
        controller: _controls,
      ),
      const SizedBox(height: 16),
      ChargingPowerCard(
        preview: widget.preview,
        persistOnBoot: widget.persistOnBoot,
        controller: _controls,
      ),
    ],
  );
}
