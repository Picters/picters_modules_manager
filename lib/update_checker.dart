import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// Where app releases are published — see build.rs's build_oot_module_zip:
/// this app is deliberately released independently of the kernel/module zip,
/// so it can update itself here without waiting on a new kernel build.
const String kUpdateRepo = 'Picters/picters_modules_manager';

/// Where kernel + OOT-modules builds are released (date-tagged zips, published
/// by build.rs's do_release step). The app watches this for the matching build.
const String kKernelRepo = 'Picters/android_kernel_xiaomi_sm8850-extra';

/// Packs a "YYYYMMDD-HHMM" build stamp into the same monotonic int the module's
/// module.prop carries (must match build.rs module_version_code). 0 if unparsed.
int moduleVersionCode(String yyyymmdd, String hhmm) {
  final ymd = int.tryParse(yyyymmdd);
  final hm = int.tryParse(hhmm);
  if (ymd == null || hm == null) return 0;
  return (ymd - 20200000) * 10000 + hm;
}

/// An available kernel/OOT-modules build: the two flashable zips plus the packed
/// versionCode parsed from their date-stamped names.
class KernelUpdateInfo {
  const KernelUpdateInfo({
    required this.versionCode,
    required this.dateLabel,
    required this.modulesUrl,
    required this.modulesName,
    required this.kernelUrl,
    required this.kernelName,
    required this.notes,
  });

  final int versionCode;
  final String dateLabel; // e.g. "20260719-2228"
  final String modulesUrl;
  final String modulesName;
  final String? kernelUrl;
  final String? kernelName;
  final String notes;
}

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

  /// Checks the kernel repo for the newest build that ships an OOT-modules zip
  /// (skips the ci-core-latest binary release). Returns its two zip URLs + the
  /// packed versionCode, or null if none / offline / the API call fails.
  Future<KernelUpdateInfo?> checkKernel() async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(
              'https://api.github.com/repos/$kKernelRepo/releases?per_page=15'))
          .timeout(const Duration(seconds: 10));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'PictersModulesManager');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final releases = (jsonDecode(body) as List?) ?? const [];

      // Releases come newest-first; take the first that carries a modules zip.
      final stamp = RegExp(r'(\d{8})-(\d{4})\.zip$');
      for (final r in releases) {
        final rel = r as Map<String, dynamic>;
        if (rel['draft'] == true) continue;
        final assets = (rel['assets'] as List?) ?? const [];
        String? modulesUrl, modulesName, kernelUrl, kernelName;
        for (final a in assets) {
          final asset = a as Map<String, dynamic>;
          final name = asset['name'] as String? ?? '';
          final url = asset['browser_download_url'] as String?;
          if (url == null || !name.toLowerCase().endsWith('.zip')) continue;
          // These names become file paths and shell arguments as root (module
          // install, /sdcard/Download copy, AnyKernel3 unzip/flash), so refuse
          // any that isn't a plain filename — a crafted release asset otherwise
          // gives shell injection. A skipped kernel asset just drops the flash;
          // a skipped modules asset skips the whole release below.
          if (!isSafeAssetName(name)) continue;
          if (name.contains('OOT-Modules')) {
            modulesUrl = url;
            modulesName = name;
          } else if (name.contains('Kernel')) {
            kernelUrl = url;
            kernelName = name;
          }
        }
        if (modulesUrl == null || modulesName == null) continue;

        final m = stamp.firstMatch(modulesName);
        if (m == null) continue;
        return KernelUpdateInfo(
          versionCode: moduleVersionCode(m.group(1)!, m.group(2)!),
          dateLabel: '${m.group(1)}-${m.group(2)}',
          modulesUrl: modulesUrl,
          modulesName: modulesName,
          kernelUrl: kernelUrl,
          kernelName: kernelName,
          notes: (rel['body'] as String? ?? '').trim(),
        );
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads a release zip to [destPath], retrying transient failures and
  /// checking it's a real (PK-magic) zip of the declared size before returning.
  Future<File> downloadZip(String url, String destPath,
      {void Function(int received, int total)? onProgress}) async {
    final file = File(destPath);
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url));
        req.headers.set('User-Agent', 'PictersModulesManager');
        final res = await req.close().timeout(const Duration(seconds: 120));
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
        final len = await file.length();
        if (len < 1024 || (total > 0 && len != total)) {
          throw Exception('bad zip size: got $len, expected $total');
        }
        final header = await file.openRead(0, 4).expand((c) => c).toList();
        if (!hasApkMagic(header)) {
          throw Exception('downloaded file is not a valid zip');
        }
        return file;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      } finally {
        client.close(force: true);
      }
    }
    throw Exception('zip download failed after 3 attempts: $lastError');
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

/// A release asset name safe to splice into a root shell command and use as a
/// file path: a single path segment of only letters, digits, dot, underscore,
/// plus and hyphen. Rejects anything with quotes, `$`, `;`, whitespace, a
/// slash, or other shell metacharacters — and the empty string. Pure, so the
/// injection guard in [UpdateChecker.checkKernel] can be unit-tested.
bool isSafeAssetName(String name) =>
    name.isNotEmpty && RegExp(r'^[A-Za-z0-9._+-]+$').hasMatch(name);

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
