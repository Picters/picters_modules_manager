import 'dart:async';

import 'package:flutter/foundation.dart';
import 'thermal_device_repository.dart';

/// Thermal presets are independent from CPU/GPU performance profiles.
enum ThermalPreset {
  stock('Stock'),
  balanced('Balanced'),
  gaming('Gaming'),
  custom('Custom');

  const ThermalPreset(this.label);
  final String label;
}

/// A preview capability is simulated; unverified never enables device writes.
enum DeviceControlSupport { preview, available, unverified }

@immutable
class DeviceBatteryStatus {
  const DeviceBatteryStatus({
    required this.levelPercent,
    required this.temperatureC,
    required this.voltageV,
    required this.currentA,
  });

  final int levelPercent;
  final double temperatureC;
  final double voltageV;
  final double currentA;
}

@immutable
class DeviceAdapterStatus {
  const DeviceAdapterStatus({
    required this.connected,
    required this.voltageV,
    required this.currentA,
  });

  final bool connected;
  final double voltageV;
  final double currentA;
  double get powerW => voltageV * currentA;
}

@immutable
class DeviceControlSettings {
  const DeviceControlSettings({
    this.thermalPreset = ThermalPreset.stock,
    this.customTemp = 45,
    this.thermalLimitDisabled = false,
    this.persistOnBoot = false,
    this.inputLimit = 100,
    this.inputLimitDisabled = false,
    this.chargeLimit = 100,
    this.bypassRequested = false,
    this.chargingEnabled = false,
  });

  final ThermalPreset thermalPreset;
  final double customTemp;
  final bool thermalLimitDisabled;
  final bool persistOnBoot;
  final double inputLimit;
  final bool inputLimitDisabled;
  final double chargeLimit;
  final bool bypassRequested;
  final bool chargingEnabled;

  DeviceControlSettings copyWith({
    ThermalPreset? thermalPreset,
    double? customTemp,
    bool? thermalLimitDisabled,
    bool? persistOnBoot,
    double? inputLimit,
    bool? inputLimitDisabled,
    double? chargeLimit,
    bool? bypassRequested,
    bool? chargingEnabled,
  }) => DeviceControlSettings(
    thermalPreset: thermalPreset ?? this.thermalPreset,
    customTemp: customTemp ?? this.customTemp,
    thermalLimitDisabled: thermalLimitDisabled ?? this.thermalLimitDisabled,
    persistOnBoot: persistOnBoot ?? this.persistOnBoot,
    inputLimit: inputLimit ?? this.inputLimit,
    inputLimitDisabled: inputLimitDisabled ?? this.inputLimitDisabled,
    chargeLimit: chargeLimit ?? this.chargeLimit,
    bypassRequested: bypassRequested ?? this.bypassRequested,
    chargingEnabled: chargingEnabled ?? this.chargingEnabled,
  );
}

@immutable
class DeviceControlsState {
  const DeviceControlsState({
    required this.support,
    this.settings = const DeviceControlSettings(),
    this.battery,
    this.adapter,
    this.thermalAvailable = false,
    this.chargingAvailable = false,
  });

  final DeviceControlSupport support;
  final DeviceControlSettings settings;
  final DeviceBatteryStatus? battery;
  final DeviceAdapterStatus? adapter;
  final bool thermalAvailable;
  final bool chargingAvailable;

  static const unverified = DeviceControlsState(
    support: DeviceControlSupport.unverified,
  );

  static const demo = DeviceControlsState(
    support: DeviceControlSupport.preview,
    battery: DeviceBatteryStatus(
      levelPercent: 72,
      temperatureC: 36.8,
      voltageV: 4.12,
      currentA: 1.4,
    ),
    adapter: DeviceAdapterStatus(connected: true, voltageV: 9, currentA: 3),
  );

  DeviceControlsState withSettings(DeviceControlSettings value) =>
      DeviceControlsState(
        support: support,
        settings: value,
        battery: battery,
        adapter: adapter,
        thermalAvailable: thermalAvailable,
        chargingAvailable: chargingAvailable,
      );
}

/// Preview stays in memory; Android requires matching pack and vendor APIs.
abstract class DeviceControlsRepository {
  factory DeviceControlsRepository({bool preview = false}) =>
      preview ? DemoDeviceControlsRepository() : XiaomiThermalRepository();

  bool get preview;
  DeviceControlsState get initialState;
  Future<DeviceControlsState> scan();
  Future<DeviceControlsState> apply(DeviceControlSettings settings);
}

/// Holds demo selections in memory only. No settings survive process exit.
class DemoDeviceControlsRepository implements DeviceControlsRepository {
  DeviceControlsState _state = DeviceControlsState.demo;

  @override
  bool get preview => true;

  @override
  DeviceControlsState get initialState => _state;

  @override
  Future<DeviceControlsState> scan() async => _state;

  @override
  Future<DeviceControlsState> apply(DeviceControlSettings settings) async {
    _state = _state.withSettings(settings);
    return _state;
  }
}

/// Thermal policy paths and bypass support have not been verified on hardware.
/// Production stays unavailable instead of inferring support from a filename.
class UnverifiedDeviceControlsRepository implements DeviceControlsRepository {
  @override
  bool get preview => false;

  @override
  DeviceControlsState get initialState => DeviceControlsState.unverified;

  @override
  Future<DeviceControlsState> scan() async => initialState;

  @override
  Future<DeviceControlsState> apply(DeviceControlSettings settings) async =>
      throw UnsupportedError(DeviceControlsController.verificationPending);
}

class DeviceControlsController extends ChangeNotifier {
  DeviceControlsController({
    bool preview = false,
    DeviceControlsRepository? repository,
  }) : _repository = repository ?? DeviceControlsRepository(preview: preview) {
    state = _repository.initialState;
  }

  final DeviceControlsRepository _repository;
  late DeviceControlsState state;
  bool busy = false;
  String? lastError;
  bool _disposed = false;
  Completer<void>? _idle;
  bool? _requestedPersistence;

  // Preview interaction ranges, not hardware specifications or battery limits.
  static const double minCustomTemp = 25;
  static const double maxCustomTemp = 65;
  static const double minInputLimit = 1;
  static const double maxInputLimit = 120;
  static const double minChargeLimit = 50;
  static const double maxChargeLimit = 100;
  static const verificationPending =
      'Device verification pending. Thermal and charging controls are unavailable.';

  bool get preview => _repository.preview;
  bool get thermalSupported =>
      state.support == DeviceControlSupport.preview || state.thermalAvailable;
  bool get bypassSupported => state.support == DeviceControlSupport.preview;
  bool get inputLimitSupported =>
      state.support == DeviceControlSupport.preview || state.chargingAvailable;
  bool get chargeLimitSupported =>
      state.support == DeviceControlSupport.preview;
  bool get supported => thermalSupported || bypassSupported;
  ThermalPreset get thermalPreset => state.settings.thermalPreset;
  double get customTemp => state.settings.customTemp;
  bool get thermalLimitDisabled => state.settings.thermalLimitDisabled;
  double get inputLimit => state.settings.inputLimit;
  bool get inputLimitDisabled => state.settings.inputLimitDisabled;
  double get chargeLimit => state.settings.chargeLimit;
  bool get bypassRequested => state.settings.bypassRequested;
  bool get chargingEnabled => state.settings.chargingEnabled;
  bool get powerControlAllowed =>
      thermalPreset == ThermalPreset.custom && thermalLimitDisabled;
  static const powerRequiresThermalOff = 'Set Custom throttling to Off first.';
  DeviceBatteryStatus? get battery => state.battery;
  DeviceAdapterStatus? get adapter => state.adapter;
  String get availabilityMessage => preview
      ? 'Preview only. Demo values do not change device settings.'
      : thermalSupported
      ? 'Custom CPU/GPU thermal profiles are available.'
      : verificationPending;

  Future<void> init() => refresh();

  Future<void> refresh() async {
    final next = await _repository.scan();
    if (_disposed) return;
    state = next;
    notifyListeners();
  }

  Future<bool> setThermalPreset(ThermalPreset value) =>
      value == ThermalPreset.stock
      ? restoreThermalStock()
      : _apply(state.settings.copyWith(thermalPreset: value), thermalSupported);

  Future<bool> setCustomTemp(double value) {
    if (!_within(value, minCustomTemp, maxCustomTemp) ||
        value != value.roundToDouble()) {
      return _invalid('Choose a thermal target between 25 and 65 °C.');
    }
    return _apply(
      state.settings.copyWith(
        thermalPreset: ThermalPreset.custom,
        customTemp: value,
        thermalLimitDisabled: false,
      ),
      thermalSupported,
    );
  }

  Future<bool> setThermalLimitDisabled(bool value) => _apply(
    state.settings.copyWith(
      thermalPreset: ThermalPreset.custom,
      thermalLimitDisabled: value,
    ),
    thermalSupported,
  );

  Future<bool> setBootPersistence(bool value) async {
    _requestedPersistence = value;
    // A profile write may still be using the old flag. Apply the latest choice
    // after it finishes, retaining the newly applied profile and temperature.
    while (busy && !_disposed) {
      await _idle!.future;
    }
    if (_disposed) return false;
    final requested = _requestedPersistence!;
    if (state.settings.persistOnBoot == requested) return true;
    return _apply(
      state.settings.copyWith(persistOnBoot: requested),
      thermalSupported,
    );
  }

  Future<bool> setInputLimit(double value) {
    if (!_within(value, minInputLimit, maxInputLimit) ||
        value != value.roundToDouble()) {
      return _invalid('Choose a whole-watt limit between 1 and 120 W.');
    }
    if (inputLimitSupported && !powerControlAllowed) {
      return _invalid(powerRequiresThermalOff);
    }
    return _apply(
      state.settings.copyWith(inputLimit: value, inputLimitDisabled: false),
      inputLimitSupported,
    );
  }

  /// No app-imposed input power cap; hardware charging protections still apply.
  Future<bool> clearInputLimit() {
    if (inputLimitSupported && !powerControlAllowed) {
      return _invalid(powerRequiresThermalOff);
    }
    return _apply(
      state.settings.copyWith(inputLimitDisabled: true),
      inputLimitSupported,
    );
  }

  Future<bool> setPowerControlEnabled(bool value) {
    if (value && inputLimitSupported && !powerControlAllowed) {
      return _invalid(powerRequiresThermalOff);
    }
    return value
        ? _apply(
            state.settings.copyWith(chargingEnabled: true),
            inputLimitSupported,
          )
        : restoreChargingStock();
  }

  Future<bool> setChargeLimit(double value) {
    if (!_within(value, minChargeLimit, maxChargeLimit)) {
      return _invalid('Choose a charge limit between 50 and 100%.');
    }
    return _apply(
      state.settings.copyWith(chargeLimit: value),
      chargeLimitSupported,
    );
  }

  Future<bool> setBypassRequested(bool value) =>
      _apply(state.settings.copyWith(bypassRequested: value), bypassSupported);

  Future<bool> setChargingEnabled(bool value) => setPowerControlEnabled(value);

  Future<bool> restoreThermalStock() {
    const defaults = DeviceControlSettings();
    return _apply(
      state.settings.copyWith(
        thermalPreset: defaults.thermalPreset,
        customTemp: defaults.customTemp,
        thermalLimitDisabled: false,
      ),
      thermalSupported,
    );
  }

  Future<bool> restoreChargingStock() {
    const defaults = DeviceControlSettings();
    return _apply(
      state.settings.copyWith(
        bypassRequested: defaults.bypassRequested,
        chargingEnabled: defaults.chargingEnabled,
        inputLimit: defaults.inputLimit,
        inputLimitDisabled: defaults.inputLimitDisabled,
        chargeLimit: defaults.chargeLimit,
      ),
      bypassSupported && inputLimitSupported && chargeLimitSupported,
    );
  }

  /// Restores the pack-owned thermal files and releases its charging votes.
  Future<bool> restoreStock() =>
      _apply(const DeviceControlSettings(), supported);

  bool _within(double value, double min, double max) =>
      value.isFinite && value >= min && value <= max;

  Future<bool> _invalid(String message) async {
    if (_disposed) return false;
    lastError = message;
    notifyListeners();
    return false;
  }

  Future<bool> _apply(DeviceControlSettings settings, bool available) async {
    if (_disposed || busy) return false;
    if (!available) return _invalid(verificationPending);
    if (settings.thermalPreset != ThermalPreset.custom ||
        !settings.thermalLimitDisabled) {
      settings = settings.copyWith(
        chargingEnabled: false,
        inputLimit: const DeviceControlSettings().inputLimit,
        inputLimitDisabled: false,
      );
    }
    busy = true;
    final idle = _idle = Completer<void>();
    lastError = null;
    notifyListeners();
    try {
      final next = await _repository.apply(settings);
      if (_disposed) return false;
      state = next;
      return true;
    } catch (error) {
      // A combined operation can restore charging before thermal activation
      // fails. Show the actual remaining state instead of the previous request.
      try {
        final live = await _repository.scan();
        if (!_disposed) state = live;
      } catch (_) {
        // Keep the original failure if the root connection also went away.
      }
      if (!_disposed) lastError = 'Could not apply controls: $error';
      return false;
    } finally {
      busy = false;
      idle.complete();
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
