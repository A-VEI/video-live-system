/// 网页同款 HLS（WebView + hls.js）
/// 切频道只换地址，不重建 WebView（避免系统卡死）
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
  String _abs = '';
  bool _ready = false;
  String _status = '正在加载…';
  Timer? _fallbackTimer;

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
          'window.__HLS_SRC__ = ${_jsQuote(_abs)}; if(window.__hlsBoot) window.__hlsBoot(true);');
    } catch (_) {}
  }

  void _onStatus(String st) {
    if (!mounted) return;
    setState(() => _status = st);
    if (st == 'playing' || st.isEmpty) {
      setState(() => _status = '');
    }
    if (st.contains('不支持') || st.contains('缺少') || st.contains('播放组件未加载')) {
      _scheduleFallback();
    } else if (st.contains('播放出错')) {
      _scheduleFallback(const Duration(seconds: 3));
    } else if (st.contains('网络中断')) {
      _scheduleFallback(const Duration(seconds: 8));
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _abs = ApiClient.instance.absoluteUrl(widget.proxyUrl);
    final playerUri = Uri.parse('${ApiClient.instance.baseUrl}/static/mobile-player.html');

    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (msg) {
          final s = msg.message;
          if (s.startsWith('status:')) _onStatus(s.substring(7));
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
          },
        ),
      )
      ..loadRequest(playerUri);
  }

  @override
  void didUpdateWidget(covariant HlsWebViewPlayer old) {
    super.didUpdateWidget(old);
    if (old.proxyUrl != widget.proxyUrl) {
      _abs = ApiClient.instance.absoluteUrl(widget.proxyUrl);
      _boot(); // 同一 WebView 内换流
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fallbackTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {
        _ready = false;
        _status = '正在恢复…';
      });
      try {
        _c.reload();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        WebViewWidget(controller: _c),
        if (!_ready || _status.contains('加载') || _status == '正在恢复…')
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 12),
                Text(_status,
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
      ],
    );
  }
}
