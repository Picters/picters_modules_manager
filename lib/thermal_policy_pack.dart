import 'dart:typed_data';

import 'thermal_profile.dart';

/// An in-memory set of overrides prepared from the installed ODM baseline.
/// Generating every scenario prevents an app/game switch from selecting an
/// unedited policy. This class neither deploys files nor restarts any service.
class ThermalPolicyPack {
  ThermalPolicyPack._({
    required this.vendorFingerprint,
    required this.temperatureC,
    required this.disabled,
    required Map<String, ThermalProfileDraft> policies,
  }) : policies = Map.unmodifiable(policies);

  final String vendorFingerprint;
  final int temperatureC;
  final bool disabled;
  final Map<String, ThermalProfileDraft> policies;
  static final _filename = RegExp(r'^thermal-[a-z0-9-]+\.conf$');

  static ThermalPolicyPack prepare({
    required String vendorFingerprint,
    required Map<String, String> stockPolicies,
    required int temperatureC,
    bool disabled = false,
  }) {
    if (vendorFingerprint.trim().isEmpty ||
        vendorFingerprint.contains('\n') ||
        vendorFingerprint.contains('\r')) {
      throw const FormatException('Missing or invalid vendor fingerprint.');
    }
    if (stockPolicies.isEmpty) {
      throw const FormatException('Missing installed stock thermal policies.');
    }
    final prepared = <String, ThermalProfileDraft>{};
    for (final name in stockPolicies.keys.toList()..sort()) {
      if (!_filename.hasMatch(name)) {
        throw const FormatException('Invalid thermal policy filename.');
      }
      final draft = ThermalProfileBuilder.buildIfApplicable(
        stockPolicies[name]!,
        temperatureC: temperatureC,
        disabled: disabled,
      );
      if (draft != null) prepared[name] = draft;
    }
    if (prepared.isEmpty) {
      throw const FormatException('No verified CPU/GPU thermal rules found.');
    }
    return ThermalPolicyPack._(
      vendorFingerprint: vendorFingerprint,
      temperatureC: temperatureC,
      disabled: disabled,
      policies: prepared,
    );
  }

  /// Encode and verify the WHOLE set before returning any deployment input.
  /// Android supplies the custom-file codec, separate from the ODM stock codec.
  Future<Map<String, Uint8List>> encodeVerified({
    required Future<Uint8List> Function(String) encode,
    required Future<String> Function(Uint8List) decode,
  }) async {
    final encoded = <String, Uint8List>{};
    for (final entry in policies.entries) {
      final bytes = await encode(entry.value.text);
      if (bytes.isEmpty || await decode(bytes) != entry.value.text) {
        throw FormatException(
          'Thermal codec verification failed: ${entry.key}',
        );
      }
      encoded[entry.key] = Uint8List.fromList(bytes);
    }
    return Map.unmodifiable(encoded);
  }
}
