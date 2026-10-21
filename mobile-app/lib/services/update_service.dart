import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../api/api_client.dart';
import '../config.dart';

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

class UpdateCheckResult {
  final bool hasUpdate;
  final String version;
  final String current;
  final String updateUrl;
  final String sha256;
  final String notes;
  final int serverBuild;
  final int localBuild;
  final String reason;

  UpdateCheckResult({
    required this.hasUpdate,
    required this.version,
    required this.current,
    required this.updateUrl,
    required this.sha256,
    required this.notes,
    required this.serverBuild,
    required this.localBuild,
    required this.reason,
  });
}

class UpdateService {
  /// 检查更新。返回结果对象，便于 UI 显示「为什么没有更新」。
  static Future<UpdateCheckResult> check() async {
    final current = await AppVersion.current();
    try {
      final data = await ApiClient.instance.checkVersion();
      if (data == null) {
        return UpdateCheckResult(
          hasUpdate: false,
          version: current,
          current: current,
          updateUrl: '',
          sha256: '',
          notes: '',
          serverBuild: 0,
          localBuild: kBuildId,
          reason: '无法连接服务器',
        );
      }

      final latest = (data['version'] as String?) ?? current;
      final updateUrl = ApiClient.instance.absoluteUrl(
        (data['update_url'] as String?) ?? '/api/app/download',
      );
      final sha = (data['sha256'] as String?) ?? '';
      final notes = (data['notes'] as String?) ?? '';
      final serverBuild = _asInt(data['build_id']);
      final localBuild = kBuildId;

      // 规则 1：build_id 都有效时，只看 build_id（部署时必须与 CI 同号）
      if (serverBuild > 0 && localBuild > 0) {
        final up = serverBuild > localBuild;
        return UpdateCheckResult(
          hasUpdate: up,
          version: latest,
          current: current,
          updateUrl: updateUrl,
          sha256: sha,
          notes: notes,
          serverBuild: serverBuild,
          localBuild: localBuild,
          reason: up
              ? '有新构建 $serverBuild > $localBuild'
              : '已是最新构建 $localBuild',
        );
      }

      // 规则 2：包内无 build 号（kBuildId=0）→ 只比版本；
      // 版本相同一律不提示，避免“同版本号反复要求更新”
      final cmp = _compareVersion(latest, current);
      if (localBuild == 0 && cmp <= 0) {
        return UpdateCheckResult(
          hasUpdate: false,
          version: latest,
          current: current,
          updateUrl: updateUrl,
          sha256: sha,
          notes: notes,
          serverBuild: serverBuild,
          localBuild: localBuild,
          reason: '版本相同 $current（无构建号）',
        );
      }
      if (cmp > 0) {
        return UpdateCheckResult(
          hasUpdate: true,
          version: latest,
          current: current,
          updateUrl: updateUrl,
          sha256: sha,
          notes: notes,
          serverBuild: serverBuild,
          localBuild: localBuild,
          reason: '版本 $latest > $current',
        );
      }

      return UpdateCheckResult(
        hasUpdate: false,
        version: latest,
        current: current,
        updateUrl: updateUrl,
        sha256: sha,
        notes: notes,
        serverBuild: serverBuild,
        localBuild: localBuild,
        reason: serverBuild == 0 && localBuild == 0
            ? '版本相同 $current'
            : '无更新（server=$serverBuild local=$localBuild ver=$latest）',
      );
    } catch (e) {
      return UpdateCheckResult(
        hasUpdate: false,
        version: current,
        current: current,
        updateUrl: '',
        sha256: '',
        notes: '',
        serverBuild: 0,
        localBuild: kBuildId,
        reason: '检查失败: $e',
      );
    }
  }

  /// 兼容旧调用：有更新返回 Map，否则 null
  static Future<Map<String, dynamic>?> checkUpdate() async {
    final r = await check();
    if (!r.hasUpdate) return null;
    return {
      'version': r.version,
      'current': r.current,
      'update_url': r.updateUrl,
      'sha256': r.sha256,
      'notes': r.notes,
      'build_id': r.serverBuild,
      'local_build_id': r.localBuild,
    };
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '') ?? 0;
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
    if (expectSha256 != null && expectSha256.isNotEmpty) {
      final digest = await _fileSha256(savePath);
      if (digest.toLowerCase() != expectSha256.toLowerCase()) {
        try {
          File(savePath).deleteSync();
        } catch (_) {}
        throw Exception('完整性校验失败');
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
    final ver = widget.update['version']?.toString() ?? '';
    final cur = widget.update['current']?.toString() ?? '';
    final sb = widget.update['build_id'];
    final lb = widget.update['local_build_id'];
    return AlertDialog(
      title: Text('发现新版本 $ver'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('当前: $cur'),
          if (sb != null && lb != null)
            Text('构建: $lb → $sb', style: const TextStyle(fontSize: 12)),
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
