import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// Where app releases are published — see build.rs's build_oot_module_zip:
/// this app is deliberately released independently of the kernel/module zip,
/// so it can update itself here without waiting on a new kernel build.
const String kUpdateRepo = 'Picters/picters_modules_manager';

class UpdateInfo {
  const UpdateInfo({required this.version, required this.apkUrl, required this.notes});

  final String version;
  final String apkUrl;
  final String notes;
}

/// Checks GitHub Releases for a newer APK than the one currently installed.
class UpdateChecker {
  /// Returns the available update, or null if already current / offline /
  /// the API call fails for any reason — this is a best-effort background
  /// check, never something that should surface an error of its own.
  Future<UpdateInfo?> check() async {
    final client = HttpClient();
    try {
      final info = await PackageInfo.fromPlatform();
      final req = await client
          .getUrl(Uri.parse('https://api.github.com/repos/$kUpdateRepo/releases/latest'))
          .timeout(const Duration(seconds: 10));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'PictersModulesManager');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final tag = (json['tag_name'] as String? ?? '').trim();
      final remoteVersion = tag.startsWith('v') ? tag.substring(1) : tag;
      if (remoteVersion.isEmpty || !_isNewer(remoteVersion, info.version)) {
        return null;
      }

      final assets = (json['assets'] as List?) ?? const [];
      String? apkUrl;
      for (final a in assets) {
        final name = (a as Map<String, dynamic>)['name'] as String? ?? '';
        if (name.toLowerCase().endsWith('.apk')) {
          apkUrl = a['browser_download_url'] as String?;
          break;
        }
      }
      if (apkUrl == null) return null;

      return UpdateInfo(
        version: remoteVersion,
        apkUrl: apkUrl,
        notes: (json['body'] as String? ?? '').trim(),
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Dotted-numeric version compare (1.2.3 vs 1.10.0) — falls back to a
  /// plain string inequality if either side has a non-numeric part.
  bool _isNewer(String remote, String local) {
    final r = remote.split('.').map(int.tryParse).toList();
    final l = local.split('.').map(int.tryParse).toList();
    if (r.contains(null) || l.contains(null)) return remote != local;
    for (var i = 0; i < r.length || i < l.length; i++) {
      final rv = i < r.length ? r[i]! : 0;
      final lv = i < l.length ? l[i]! : 0;
      if (rv != lv) return rv > lv;
    }
    return false;
  }

  /// Downloads the release APK into the app's own cache dir. Root (used for
  /// the actual `pm install`) can read app-private storage fine, so this
  /// never needs to touch public/shared storage.
  Future<File> download(String url, {void Function(int received, int total)? onProgress}) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'PictersModulesManager');
      final res = await req.close();
      final total = res.contentLength;
      final file = File('${Directory.systemTemp.path}/pmm_update.apk');
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in res) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.close();
      return file;
    } finally {
      client.close(force: true);
    }
  }
}
