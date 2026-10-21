import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../api/api_client.dart';
import '../config.dart';

/// 运行时读取构建版本（pubspec.version → versionName），作为版本号单一来源。
class AppVersion {
  static String? _cached;

  static Future<String> current() async {
    if (_cached != null) return _cached!;
    try {
      final info = await PackageInfo.fromPlatform();
      _cached = info.version.isNotEmpty ? info.version : kFallbackAppVersion;
    } catch (_) {
      _cached = kFallbackAppVersion;
    }
    return _cached!;
  }
}

class UpdateService {
  static Future<Map<String, dynamic>?> checkUpdate() async {
    try {
      final current = await AppVersion.current();
      final data = await ApiClient.instance.checkVersion();
      if (data == null) return null;
      final latestVersion = data['version'] as String? ?? current;
      final updateUrl = data['update_url']?.toString() ?? '/api/app/download';

      // 1) 优先比 buildId（CI 自动编号，无需手改版本号）
      final serverBuild = (data['build_id'] is int)
          ? data['build_id'] as int
          : int.tryParse(data['build_id']?.toString() ?? '') ?? 0;
      final localBuild = kBuildId;
      if (serverBuild > 0 && localBuild > 0) {
        if (serverBuild > localBuild) {
          return {
            'version': latestVersion,
            'current': current,
            'build_id': serverBuild,
            'local_build_id': localBuild,
            'update_url': ApiClient.instance.absoluteUrl(updateUrl),
            'notes': data['notes'] ?? '',
            'sha256': data['sha256'] ?? '',
          };
        }
        return null; // 同 build 或已更新
      }

      // 2) 回退：语义化版本号
      if (_compareVersion(latestVersion, current) > 0) {
        return {
          'version': latestVersion,
          'current': current,
          'update_url': ApiClient.instance.absoluteUrl(updateUrl),
          'notes': data['notes'] ?? '',
          'sha256': data['sha256'] ?? '',
        };
      }
    } catch (e) {
      debugPrint('checkUpdate: $e');
    }
    return null;
  }

static int _compareVersion(String v1, String v2) {
    final p1 = v1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final p2 = v2.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final a = i < p1.length ? p1[i] : 0;
      final b = i < p2.length ? p2[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  static Future<void> downloadAndInstall(
    String url,
    void Function(double) onProgress, {
    String? expectSha256,
  }) async {
    final dir =
        await getExternalStorageDirectory() ?? await getTemporaryDirectory();
    final savePath = '${dir.path}/video-live-update.apk';
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
    ));
    await dio.download(
      url,
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );
    // P3: APK 完整性校验，防止中间人换包
    if (expectSha256 != null && expectSha256.isNotEmpty) {
      final digest = await _fileSha256(savePath);
      if (digest.toLowerCase() != expectSha256.toLowerCase()) {
        try {
          File(savePath).deleteSync();
        } catch (_) {}
        throw Exception('APK 校验失败，已丢弃安装包');
      }
    }
    final result = await OpenFilex.open(savePath);
    debugPrint('install result: ${result.type}');
  }

  static Future<String> _fileSha256(String path) async {
    final bytes = await File(path).readAsBytes();
    return sha256.convert(bytes).toString();
  }
}

void showUpdateDialog(BuildContext context, Map<String, dynamic> update) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(update: update),
  );
}

class _UpdateDialog extends StatefulWidget {
  final Map<String, dynamic> update;
  const _UpdateDialog({required this.update});
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double _progress = 0;
  bool _downloading = false;

  Future<void> _startUpdate() async {
    setState(() => _downloading = true);
    try {
      await UpdateService.downloadAndInstall(
        widget.update['update_url'] as String,
        (p) {
          if (mounted) setState(() => _progress = p);
        },
        expectSha256: widget.update['sha256'] as String?,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('更新失败: $e')));
        setState(() {
          _downloading = false;
          _progress = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('发现新版本 ${widget.update['version']}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('当前版本: ${widget.update['current']}'),
          const SizedBox(height: 8),
          if (widget.update['notes']?.toString().isNotEmpty == true)
            Text(widget.update['notes'].toString(),
                style: TextStyle(color: Colors.grey[600])),
          const SizedBox(height: 16),
          if (_downloading) ...[
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 8),
            Text('下载中 ${(_progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 12)),
          ],
        ],
      ),
      actions: [
        if (!_downloading)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后'),
          ),
        FilledButton(
          onPressed: _downloading ? null : _startUpdate,
          child: Text(_downloading ? '下载中…' : '立即更新'),
        ),
      ],
    );
  }
}
