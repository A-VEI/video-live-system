/// 网页同款 HLS 播放（hls.js + WebView）
/// 与 Web 端相同的预缓冲策略，消除移动端 2s 分片卡顿
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../api/api_client.dart';

class HlsWebViewPlayer extends StatefulWidget {
  final String proxyUrl; // /proxy/... 或完整 http url
  final String title;

  const HlsWebViewPlayer({
    super.key,
    required this.proxyUrl,
    this.title = '',
  });

  @override
  State<HlsWebViewPlayer> createState() => _HlsWebViewPlayerState();
}

class _HlsWebViewPlayerState extends State<HlsWebViewPlayer> {
  late final WebViewController _c;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    final abs = ApiClient.instance.absoluteUrl(widget.proxyUrl);
    final playerUrl = Uri.encodeFull(
      '${ApiClient.instance.baseUrl}/static/mobile-player.html?src=${Uri.encodeComponent(abs)}',
    );
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _ready = true);
          },
          onWebResourceError: (e) {
            debugPrint('webview error: ${e.errorCode} ${e.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(playerUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        WebViewWidget(controller: _c),
        if (!_ready)
          const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
      ],
    );
  }
}
