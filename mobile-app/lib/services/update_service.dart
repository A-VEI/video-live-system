import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../api/api_client.dart';

/// 当前 App 版本 (每次发布递增)
const String kAppVersion = '1.0.1';

class UpdateService {
  static Future<Map<String, dynamic>?> checkUpdate() async {
    try {
      final resp = await Dio().get(
        '${ApiClient.instance.baseUrl}/api/app/version',
        options: Options(sendTimeout: const Duration(seconds: 10)),
      );
      final data = resp.data;
      final latestVersion = data['version'] as String?;
      if (latestVersion == null) return null;

      if (_compareVersion(latestVersion, kAppVersion) > 0) {
        return {
          'version': latestVersion,
          'current': kAppVersion,
          'update_url': '${ApiClient.instance.baseUrl}${data['update_url']}',
          'notes': data['notes'] ?? '',
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
    void Function(double) onProgress,
  ) async {
    // 用外部存储目录 (FileProvider 能访问)
    final dir = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
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
    // 安装 APK
    final result = await OpenFilex.open(savePath);
    debugPrint('install result: ${result.type}');
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
        widget.update['update_url'],
        (p) => setState(() => _progress = p),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('更新失败: $e')));
        setState(() { _downloading = false; _progress = 0; });
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
          if (widget.update['notes']?.isNotEmpty == true)
            Text(widget.update['notes'], style: TextStyle(color: Colors.grey[600])),
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
