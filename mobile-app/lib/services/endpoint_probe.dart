/// 出口测速：以「直播 2s 分片能否按时下完」为主指标。
///
/// - 主指标：下载一个真实 ts 的耗时 vs 分片时长(2s)
///   耗时 < 2s → 能跟上直播；越接近 0 越流畅
/// - 副指标：API 延迟（影响起播、列表刷新）
/// - 综合分：segMs * 2 + apiMs  （分片下载时间权重更高）
library;

import 'dart:math';
import 'package:dio/dio.dart';
import '../config.dart';

class EndpointHealth {
  final ServerEndpoint endpoint;
  final bool ok;
  final int apiMs;
  final int? segMs;
  final int? segBytes;
  final String? error;

  EndpointHealth({
    required this.endpoint,
    required this.ok,
    required this.apiMs,
    this.segMs,
    this.segBytes,
    this.error,
  });

  /// 是否跟得上 2s 直播分片
  bool get keepsUp => segMs != null && segMs! < 2000;

  /// Mbps（若有分片数据）
  double? get mbps {
    if (segBytes == null || segMs == null || segMs == 0) return null;
    return segBytes! * 8 / 1000 / segMs!; // 近似
  }

  /// 分数越小越好：优先分片下载速度
  double get score {
    if (!ok) return 1e12;
    final s = (segMs ?? apiMs * 3).toDouble();
    return s * 2.0 + apiMs;
  }

  String get label {
    if (!ok) return '${endpoint.label} 不可达';
    final parts = <String>['${endpoint.label}'];
    if (segMs != null) parts.add('分片${segMs}ms');
    if (mbps != null) parts.add('${mbps!.toStringAsFixed(1)}Mbps');
    parts.add('${apiMs}ms');
    if (keepsUp) parts.add('流畅');
    return parts.join(' ');
  }

  @override
  String toString() => label;
}

class EndpointProbe {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 6),
    validateStatus: (_) => true,
  ));

  /// 测试用小分片路径（服务端 Nginx 直连编码器）
  static const String _segPath =
      '/proxy/192.168.181.106/live/0/hls.m3u8';

  static Future<int> _apiLatency(ServerEndpoint ep) async {
    final sw = Stopwatch()..start();
    try {
      final r = await _dio.get('${ep.baseUrl}/api/app/version');
      sw.stop();
      if (r.statusCode != 200) return 9999;
      return sw.elapsedMilliseconds;
    } catch (_) {
      sw.stop();
      return 9999;
    }
  }

  /// 下载 m3u8 + 一个 ts，测真实播放路径
  static Future<EndpointHealth> probe(ServerEndpoint ep) async {
    final apiMs = await _apiLatency(ep);
    if (apiMs >= 9999) {
      return EndpointHealth(
        endpoint: ep,
        ok: false,
        apiMs: apiMs,
        error: 'API 不可达',
      );
    }
    try {
      // 1) 拉 m3u8
      final sw1 = Stopwatch()..start();
      final r1 = await _dio.get('${ep.baseUrl}$_segPath');
      sw1.stop();
      if (r1.statusCode != 200) {
        return EndpointHealth(
          endpoint: ep,
          ok: false,
          apiMs: apiMs,
          error: 'm3u8 HTTP ${r1.statusCode}',
        );
      }
      final body = r1.data is String
          ? r1.data as String
          : (r1.data?.toString() ?? '');
      final segs = body
          .split('\n')
          .where((l) => l.trim().isNotEmpty && !l.startsWith('#'))
          .toList();
      if (segs.isEmpty) {
        return EndpointHealth(
          endpoint: ep,
          ok: true,
          apiMs: apiMs,
          segMs: sw1.elapsedMilliseconds,
          error: '播放列表为空',
        );
      }
      // 2) 下载最后一个分片（最接近直播沿）
      final seg = segs.last.trim();
      final segUrl = seg.startsWith('http')
          ? seg
          : '${ep.baseUrl}/proxy/192.168.181.106/live/0/$seg';
      final sw2 = Stopwatch()..start();
      final r2 = await _dio.get<List<int>>(
        segUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      sw2.stop();
      final bytes = r2.data?.length ?? 0;
      final segMs = sw2.elapsedMilliseconds;
      final ok = r2.statusCode == 200 && bytes > 1000;
      return EndpointHealth(
        endpoint: ep,
        ok: ok,
        apiMs: apiMs,
        segMs: segMs,
        segBytes: bytes,
        error: ok ? null : '分片 HTTP ${r2.statusCode}',
      );
    } catch (e) {
      return EndpointHealth(
        endpoint: ep,
        ok: false,
        apiMs: apiMs,
        error: '$e',
      );
    }
  }

  static Future<List<EndpointHealth>> probeAll({
    List<ServerEndpoint> list = kServerEndpoints,
  }) async {
    final results = await Future.wait(list.map(probe));
    results.sort((a, b) => a.score.compareTo(b.score));
    return results;
  }

  /// 自动选优：优先「能跟上 2s 分片」且分片耗时最短
  static Future<ServerEndpoint?> bestForLive() async {
    final list = await probeAll();
    final live = list.where((h) => h.ok && h.keepsUp).toList();
    if (live.isNotEmpty) return live.first.endpoint;
    final any = list.where((h) => h.ok).toList();
    return any.isNotEmpty ? any.first.endpoint : null;
  }
}
