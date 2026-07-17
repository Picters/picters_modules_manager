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
      if (remoteVersion.isEmpty || !isNewerVersion(remoteVersion, info.version)) {
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

  /// Downloads the release APK into the app's cache dir, retrying on
  /// transient failures and validating the result before handing it back.
  Future<File> download(String url,
      {void Function(int received, int total)? onProgress}) async {
    final file = File('${Directory.systemTemp.path}/pmm_update.apk');
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url));
        req.headers.set('User-Agent', 'PictersModulesManager');
        final res = await req.close().timeout(const Duration(seconds: 60));
        if (res.statusCode != 200) {
          throw HttpException('HTTP ${res.statusCode} for $url');
        }
        final total = res.contentLength;
        final sink = file.openWrite();
        var received = 0;
        try {
          await for (final chunk in res) {
            received += chunk.length;
            sink.add(chunk);
            onProgress?.call(received, total);
          }
        } finally {
          await sink.close();
        }
        await _verifyApk(file, expectedLength: total);
        return file;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      } finally {
        client.close(force: true);
      }
    }
    throw Exception('download failed after 3 attempts: $lastError');
  }

  /// Rejects a download that isn't a plausible APK: too small, a size that
  /// disagrees with a declared Content-Length, or missing the ZIP
  /// local-file-header magic every APK begins with.
  Future<void> _verifyApk(File file, {required int expectedLength}) async {
    final len = await file.length();
    if (len < 1024) {
      throw Exception('downloaded file too small ($len bytes)');
    }
    if (expectedLength > 0 && len != expectedLength) {
      throw Exception('size mismatch: got $len, expected $expectedLength');
    }
    final header = await file.openRead(0, 4).expand((c) => c).toList();
    if (!hasApkMagic(header)) {
      throw Exception('downloaded file is not a valid APK');
    }
  }
}

/// True when [bytes] begins with the ZIP local-file-header magic `PK\x03\x04`
/// — the first bytes of every APK. Pure so it can be unit-tested.
bool hasApkMagic(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4B &&
    bytes[2] == 0x03 &&
    bytes[3] == 0x04;

/// Dotted-numeric version compare (1.2.3 vs 1.10.0) — falls back to a plain
/// string inequality if either side has a non-numeric part. True when [remote]
/// is strictly newer than [local].
bool isNewerVersion(String remote, String local) {
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
