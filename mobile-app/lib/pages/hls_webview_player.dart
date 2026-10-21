/// 网页同款 HLS 播放（hls.js + WebView）
/// 切后台再回来自动 reload，避免白屏
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../api/api_client.dart';

class HlsWebViewPlayer extends StatefulWidget {
  final String proxyUrl;
  final VoidCallback? onFallbackNative;

  const HlsWebViewPlayer({
    super.key,
    required this.proxyUrl,
    this.onFallbackNative,
  });

  @override
  State<HlsWebViewPlayer> createState() => _HlsWebViewPlayerState();
}

class _HlsWebViewPlayerState extends State<HlsWebViewPlayer>
    with WidgetsBindingObserver {
  late final WebViewController _c;
  bool _ready = false;
  String _status = '正在加载…';
  Timer? _fallbackTimer;
  late final Uri _playerUri;
  late final String _abs;

  String _jsQuote(String s) {
    final escaped = s
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '');
    return "'$escaped'";
  }

  void _scheduleFallback([Duration delay = const Duration(milliseconds: 600)]) {
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(delay, () {
      if (mounted) widget.onFallbackNative?.call();
    });
  }

  Future<void> _boot() async {
    try {
      await _c.runJavaScript(
          'window.__HLS_SRC__ = ${_jsQuote(_abs)}; if(window.__hlsBoot) window.__hlsBoot();');
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _abs = ApiClient.instance.absoluteUrl(widget.proxyUrl);
    final base = ApiClient.instance.baseUrl;
    _playerUri = Uri.parse('$base/static/mobile-player.html')
        .replace(queryParameters: {'src': _abs});

    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (msg) {
          final s = msg.message;
          if (!s.startsWith('status:')) return;
          final st = s.substring(7);
          if (mounted) setState(() => _status = st);
          // 瞬时「网络中断，重试中」不立刻回退；播放中的 status:playing 清掉文案
          if (st == 'playing' || st.isEmpty) {
            if (mounted) setState(() => _status = '');
          }
          if (st.contains('不支持') ||
              st.contains('缺少') ||
              st.contains('播放组件未加载')) {
            _scheduleFallback();
          } else if (st.contains('播放出错')) {
            _scheduleFallback(const Duration(seconds: 3));
          } else if (st.contains('网络中断')) {
            // 网络抖动：稍后若仍失败再回退
            _scheduleFallback(const Duration(seconds: 8));
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _ready = true);
            _boot();
          },
          onWebResourceError: (e) {
            debugPrint('webview error ${e.errorCode} ${e.description}');
            _scheduleFallback();
          },
        ),
      )
      ..loadRequest(_playerUri);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fallbackTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切回前台：WebView 会白屏，这里强制重载
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {
        _ready = false;
        _status = '正在恢复…';
      });
      _c.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        WebViewWidget(controller: _c),
        if (!_ready || _status.contains('加载组件') || _status == '正在恢复…')
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 12),
                Text(_status,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
      ],
    );
  }
}
