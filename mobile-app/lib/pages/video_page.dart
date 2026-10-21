import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api/api_client.dart';
import 'hls_webview_player.dart';

/// 视频页：仅流畅引擎（WebView + hls.js）
class VideoPage extends StatefulWidget {
  const VideoPage({super.key});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> with WidgetsBindingObserver {
  List<dynamic> _streams = [];
  int? _activeIdx;
  bool _loading = true;
  bool _videoLoading = false;
  String? _error;
  String? _webProxyUrl;
  int _playGen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStreams();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {});
    }
  }

  Future<void> _loadStreams() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ApiClient.instance.getStreams();
      if (!mounted) return;
      setState(() {
        _streams = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : '加载频道失败';
      });
    }
  }

  void _playStream(int idx) {
    final gen = ++_playGen;
    if (_activeIdx == idx && _webProxyUrl != null) return;
    setState(() {
      _activeIdx = idx;
      _videoLoading = true;
      _error = null;
      _webProxyUrl = null;
    });
    final stream = _streams[idx] as Map;
    final raw = (stream['proxy_url'] ?? stream['url'] ?? '') as String;
    final url = ApiClient.instance.absoluteUrl(raw);
    if (!mounted || gen != _playGen) return;
    setState(() {
      _webProxyUrl = url;
      _videoLoading = false;
    });
  }

  void _enterFullscreen() {
    if (_webProxyUrl == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenWebViewPage(
          proxyUrl: _webProxyUrl!,
          title: (_streams[_activeIdx ?? 0] as Map)['name']?.toString() ?? '',
        ),
      ),
    );
  }

  Widget _playerBox() {
    if (_webProxyUrl == null) {
      return Center(
        child: _videoLoading
            ? const CircularProgressIndicator(color: Colors.white)
            : Text(
                _error ?? '选择频道开始观看',
                style: TextStyle(
                  color: _error != null ? Colors.orange[200] : Colors.white54,
                ),
              ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        HlsWebViewPlayer(
                    proxyUrl: _webProxyUrl!,
          onFallbackNative: () {
            // 仅保留流畅引擎：失败时重试当前频道
            if (!mounted) return;
            final idx = _activeIdx;
            final url = _webProxyUrl;
            setState(() {
              _webProxyUrl = null;
              _videoLoading = true;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() {
                _webProxyUrl = url;
                _videoLoading = false;
              });
            });
            if (idx != null) _playStream(idx);
          },
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: IconButton(
            color: Colors.white,
            icon: const Icon(Icons.fullscreen),
            onPressed: _enterFullscreen,
          ),
        ),
      ],
    );
  }

  Widget _channelList() {
    return RefreshIndicator(
      onRefresh: _loadStreams,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _streams.length,
        itemBuilder: (_, i) {
          final s = _streams[i] as Map;
          final isActive = _activeIdx == i;
          final enabled = s['enabled'] == 1 || s['enabled'] == true;
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: isActive
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey[200],
              child: Text('${i + 1}',
                  style: TextStyle(
                    color: isActive ? Colors.white : Colors.grey[600],
                    fontWeight: FontWeight.bold,
                  )),
            ),
            title: Text(s['name']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              !enabled
                  ? '已停用'
                  : isActive
                      ? '正在播放…'
                      : '点击播放',
              style: TextStyle(
                  fontSize: 12,
                  color: isActive
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey),
            ),
            trailing: Icon(
              isActive ? Icons.graphic_eq : Icons.play_circle_outline,
              color: isActive
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
            ),
            selected: isActive,
            selectedTileColor:
                Theme.of(context).colorScheme.primary.withOpacity(0.05),
            onTap: enabled ? () => _playStream(i) : null,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;
        if (isLandscape) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: ColoredBox(color: Colors.black, child: _playerBox()),
              ),
              const VerticalDivider(width: 1),
              Expanded(flex: 2, child: _channelList()),
            ],
          );
        }
        return Column(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ColoredBox(color: Colors.black, child: _playerBox()),
            ),
            Expanded(child: _channelList()),
          ],
        );
      },
    );
  }
}

/// 流畅引擎全屏
class _FullscreenWebViewPage extends StatefulWidget {
  final String proxyUrl;
  final String title;
  const _FullscreenWebViewPage({required this.proxyUrl, required this.title});

  @override
  State<_FullscreenWebViewPage> createState() => _FullscreenWebViewPageState();
}

class _FullscreenWebViewPageState extends State<_FullscreenWebViewPage> {
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _armHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    super.dispose();
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _armHide();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            HlsWebViewPlayer(
                            proxyUrl: widget.proxyUrl,
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onDoubleTap: () => Navigator.of(context).pop(),
              ),
            ),
            if (_showControls)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white, size: 28),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        Expanded(
                          child: Text(
                            widget.title,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 16),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.only(right: 12),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.redAccent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('LIVE',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
