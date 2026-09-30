import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/update_checker.dart';

void main() {
  const vendor = 'Xiaomi/pudding/pudding:16/BUILD/3.0.315.0:user/release-keys';
  final device = {'android_sdk': 36, 'vendor_fingerprint': vendor};
  final manifest = <String, dynamic>{
    'schema': 1,
    'status': 'validated',
    'channel': 'android16',
    'android_sdk': 36,
    'kmi_generation': 5,
    'validated_vendor_fingerprints': [vendor],
  };
  test('only a tested firmware and correct SDK/KMI channel match', () {
    expect(kernelCompatibilityMatches(manifest, device), isTrue);
    expect(
      kernelCompatibilityMatches(manifest, {...device, 'android_sdk': 37}),
      isFalse,
    );
    expect(
      kernelCompatibilityMatches(manifest, {
        ...device,
        'vendor_fingerprint': 'other',
      }),
      isFalse,
    );
    expect(
      kernelCompatibilityMatches({...manifest, 'kmi_generation': 6}, device),
      isFalse,
    );
    expect(
      kernelCompatibilityMatches({...manifest, 'channel': 'android17'}, device),
      isFalse,
    );
  });
  test('unknown metadata and unverified builds are never offered', () {
    expect(kernelCompatibilityMatches({}, device), isFalse);
    expect(kernelCompatibilityMatches(manifest, {}), isFalse);
    expect(
      kernelCompatibilityMatches({
        ...manifest,
        'validated_vendor_fingerprints': [],
      }, device),
      isFalse,
    );
    expect(
      kernelCompatibilityMatches({
        ...manifest,
        'status': 'awaiting-device-test',
      }, device),
      isFalse,
    );
    expect(
      kernelCompatibilityMatches({...manifest, 'schema': 2}, device),
      isFalse,
    );
  });
  test('verified Android17 firmware requires its own KMI6 manifest', () {
    final next = {
      ...manifest,
      'channel': 'android17',
      'android_sdk': 37,
      'kmi_generation': 6,
    };
    expect(
      kernelCompatibilityMatches(next, {...device, 'android_sdk': 37}),
      isTrue,
    );
    expect(kernelCompatibilityMatches(next, device), isFalse);
  });
}
