import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'module_repository.dart';

/// Read-only release discovery. This class never downloads or installs assets.
class ReleasesController extends ChangeNotifier {
  ReleasesController(this._repo);
  final ModuleRepository _repo;
  bool deviceSupported = true;
  bool newReleaseAvailable = false;
  bool _disposed = false;

  Future<void> init() async {
    deviceSupported = isSupportedDevice(await _repo.deviceIdentity());
    if (_disposed) return;
    notifyListeners();
    if (!deviceSupported) return;
    final installed = await _repo.installedModulesVersionCode();
    final channel = await _repo.installedReleaseChannel();
    if (channel == null) return;
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(
            Uri.parse(
              'https://api.github.com/repos/Picters/android_kernel_xiaomi_sm8850-extra/releases?per_page=30',
            ),
          )
          .timeout(const Duration(seconds: 10));
      req.headers.set('User-Agent', 'PictersModulesManager');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      final releases = jsonDecode(body) as List;
      if (!_disposed) {
        newReleaseAvailable =
            newestManualReleaseCode(releases, channel: channel) > installed;
        notifyListeners();
      }
    } catch (_) {
      // Offline: keep the release chip hidden.
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Only our new, explicitly separated manual release format creates a notice.
int newestManualReleaseCode(List<dynamic> releases, {String? channel}) {
  var newest = 0;
  final tagPattern = RegExp(r'^(A16|A17)-(\d{8})-(\d{4})$');
  for (final release in releases) {
    if (release is! Map ||
        release['draft'] == true ||
        release['prerelease'] == true) {
      continue;
    }
    final match = tagPattern.firstMatch(release['tag_name']?.toString() ?? '');
    if (match == null) continue;
    final releaseChannel = match.group(1)!;
    if (channel != null && releaseChannel != channel) continue;
    final assets = release['assets'];
    if (assets is! List) continue;
    final names = assets.whereType<Map>().map((a) => a['name']).toSet();
    final android = releaseChannel == 'A16' ? 'android16' : 'android17';
    final stamp = '${match.group(2)}-${match.group(3)}';
    final kernelPattern = RegExp(
      '^Mi17_Kernel-[0-9]+\\.[0-9]+\\.[0-9]+-$android-[A-Za-z0-9._+-]+-$stamp\\.zip\$',
    );
    final modulesPattern = RegExp(
      '^Mi17_OOTMODULES-[0-9]+\\.[0-9]+\\.[0-9]+-$android-[A-Za-z0-9._+-]+-$stamp\\.zip\$',
    );
    final kernelNames = names.whereType<String>().where(kernelPattern.hasMatch);
    if (!kernelNames.any(
      (name) =>
          names.contains(
            name.replaceFirst('Mi17_Kernel-', 'Mi17_OOTMODULES-'),
          ) &&
          modulesPattern.hasMatch(
            name.replaceFirst('Mi17_Kernel-', 'Mi17_OOTMODULES-'),
          ),
    )) {
      continue;
    }
    final code =
        (int.parse(match.group(2)!) - 20200000) * 10000 +
        int.parse(match.group(3)!);
    if (code > newest) newest = code;
  }
  return newest;
}
