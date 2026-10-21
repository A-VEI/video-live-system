import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../api/api_client.dart';
import '../config.dart';

/// 更新判断：只比「构建时间戳 build_time」，版本号不参与。
class UpdateCheckResult {
  final bool hasUpdate;
  final String updateUrl;
  final String sha256;
  final String notes;
  final int serverBuildId;
  final int serverBuildTime;
  final int localBuildId;
  final int localBuildTime;
  final String reason;

  UpdateCheckResult({
    required this.hasUpdate,
    required this.updateUrl,
    required this.sha256,
    required this.notes,
    required this.serverBuildId,
    required this.serverBuildTime,
    required this.localBuildId,
    required this.localBuildTime,
    required this.reason,
  });
}

class UpdateService {
  static Future<UpdateCheckResult> check() async {
    final localId = kBuildId;
    final localTime = kBuildTime;
    try {
      final data = await ApiClient.instance.checkVersion();
      if (data == null) {
        return UpdateCheckResult(
          hasUpdate: false,
          updateUrl: '',
          sha256: '',
          notes: '',
          serverBuildId: 0,
          serverBuildTime: 0,
          localBuildId: localId,
          localBuildTime: localTime,
          reason: '无法连接服务器',
        );
      }

      final updateUrl = ApiClient.instance.absoluteUrl(
        (data['update_url'] as String?) ?? '/api/app/download',
      );
      final sha = (data['sha256'] as String?) ?? '';
      final notes = (data['notes'] as String?) ?? '';
      final serverId = _asInt(data['build_id']);
      final serverTime = _asInt(data['build_time']);

      // 规则：只看时间戳；时间戳缺省时用 build_id
      if (serverTime > 0 && localTime > 0) {
        final up = serverTime > localTime;
        return UpdateCheckResult(
          hasUpdate: up,
          updateUrl: updateUrl,
          sha256: sha,
          notes: notes,
          serverBuildId: serverId,
          serverBuildTime: serverTime,
          localBuildId: localId,
          localBuildTime: localTime,
          reason: up
              ? '有新构建 ${_fmtTime(serverTime)}'
              : '已是最新构建 ${_fmtTime(localTime)}',
        );
      }

      if (serverId > 0 && localId > 0) {
        final up = serverId > localId;
        return UpdateCheckResult(
          hasUpdate: up,
          updateUrl: updateUrl,
          sha256: sha,
          notes: notes,
          serverBuildId: serverId,
          serverBuildTime: serverTime,
          localBuildId: localId,
          localBuildTime: localTime,
          reason: up
              ? '有新构建 #$serverId'
              : '已是最新构建 #$localId',
        );
      }

      // 都缺构建信息：不提示（不再用版本号）
      return UpdateCheckResult(
        hasUpdate: false,
        updateUrl: updateUrl,
        sha256: sha,
        notes: notes,
        serverBuildId: serverId,
        serverBuildTime: serverTime,
        localBuildId: localId,
        localBuildTime: localTime,
        reason: '无构建信息，不提示更新',
      );
    } catch (e) {
      return UpdateCheckResult(
        hasUpdate: false,
        updateUrl: '',
        sha256: '',
        notes: '',
        serverBuildId: 0,
        serverBuildTime: 0,
        localBuildId: localId,
        localBuildTime: localTime,
        reason: '检查失败: $e',
      );
    }
  }

  static String _fmtTime(int epoch) {
    if (epoch <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${p(dt.month)}${p(dt.day)}-${p(dt.hour)}${p(dt.minute)}${p(dt.second)}';
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '') ?? 0;
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
      final bytes = await File(savePath).readAsBytes();
      final digest = sha256.convert(bytes).toString();
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
    final label = widget.update['label']?.toString() ?? '';
    return AlertDialog(
      title: Text(label.isEmpty ? '发现新构建' : '发现新构建 $label'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.update['reason']?.toString() ?? ''),
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
