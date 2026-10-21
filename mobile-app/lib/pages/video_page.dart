import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../api/api_client.dart';
import '../config.dart';
import 'hls_webview_player.dart';

class VideoPage extends StatefulWidget {
  const VideoPage({super.key});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> with WidgetsBindingObserver {
  List<dynamic> _streams = [];
  int? _activeIdx;
  int _playGen = 0; // 播放代数，快速连点防串台
  VideoPlayerController? _videoCtrl;
  bool _loading = true;
  bool _videoLoading = false;
  String? _error;
  bool _isLive = true;
  bool _useWebEngine = true;
  bool _failoverTried = false;
  String? _webProxyUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStreams();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _videoCtrl?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切回前台：强制重建，避免白屏
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

  Future<void> _playStreamNative(int idx) async {
    final gen = ++_playGen;
    setState(() {
      _useWebEngine = false;
      _videoLoading = true;
      _error = null;
      _webProxyUrl = null;
    });
    final stream = _streams[idx] as Map;
    final rawProxy = (stream['proxy_url'] ?? stream['url'] ?? '') as String;
    final url = ApiClient.instance.absoluteUrl(rawProxy);
    try {
      final vc = VideoPlayerController.networkUrl(
        Uri.parse(url),
        formatHint: VideoFormat.hls,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      await vc.initialize();
      if (!mounted || gen != _playGen) {
        vc.dispose();
        return;
      }
      await vc.play();
      if (!mounted || gen != _playGen) {
        vc.dispose();
        return;
      }
      setState(() {
        _videoCtrl = vc;
        _videoLoading = false;
        _isLive = true;
      });
    } catch (e) {
      if (!mounted || gen != _playGen) return;
      setState(() {
        _videoLoading = false;
        _videoCtrl = null;
        _error = describePlayError(e);
      });
    }
  }

  Future<void> _playStream(int idx) async {
    final gen = ++_playGen;
    if (_activeIdx == idx &&
        (_videoCtrl?.value.isPlaying == true || _webProxyUrl != null)) {
      return;
    }
    setState(() {
      _activeIdx = idx;
      _videoLoading = true;
      _error = null;
      _webProxyUrl = null;
    });
    _useWebEngine = ApiClient.instance.playEngine == PlayEngine.hlsjs;
    if (_useWebEngine) {
      final stream = _streams[idx] as Map;
      final raw = (stream['proxy_url'] ?? stream['url'] ?? '') as String;
      if (!mounted || gen != _playGen) return;
      setState(() {
        _webProxyUrl = ApiClient.instance.absoluteUrl(raw);
        _videoLoading = false;
        _isLive = true;
      });
      return;
    }
    await _playStreamNative(idx);
  }

  Future<void> _retryCurrent() async {
    _failoverTried = false;
    final idx = _activeIdx;
    if (idx == null) return;
    // 先刷新签名 URL 再重试
    try {
      final data = await ApiClient.instance.getStreams();
      if (!mounted) return;
      setState(() => _streams = data);
    } catch (_) {}
    await _playStream(idx);
  }

  void _enterFullscreen() {
    if (_useWebEngine && _webProxyUrl != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _FullscreenWebViewPage(
            proxyUrl: _webProxyUrl!,
            title: _streams[_activeIdx ?? 0]['name']?.toString() ?? '',
          ),
        ),
      );
      return;
    }
    final ctrl = _videoCtrl;
    if (ctrl == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenVideoPage(
          controller: ctrl,
          title: _streams[_activeIdx!]['name']?.toString() ?? '',
          isLive: _isLive,
        ),
      ),
    );
  }

  @override
  Widget _videoPlayerBox({double? fixedHeight}) {
    final video = _useWebEngine && _webProxyUrl != null
        ? HlsWebViewPlayer(
            proxyUrl: _webProxyUrl!,
            onFallbackNative: () {
              if (!mounted) return;
              setState(() {
                _useWebEngine = false;
                _videoLoading = true;
                _webProxyUrl = null;
              });
              final idx = _activeIdx;
              if (idx != null) _playStreamNative(idx);
            },
          )
        : (_videoCtrl != null && _videoCtrl!.value.isInitialized)
            ? Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  VideoPlayer(_videoCtrl!),
                  _ControlsBar(
                    controller: _videoCtrl!,
                    isLive: _isLive,
                    onFullscreen: _enterFullscreen,
                  ),
                ],
              )
            : Center(
                child: _videoLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error ?? '选择频道开始观看',
                            style: TextStyle(
                              color: _error != null
                                  ? Colors.orange[200]
                                  : Colors.white54,
                              fontSize: 14,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: _retryCurrent,
                              child: const Text('重试'),
                            ),
                          ],
                        ],
                      ),
              );

    final box = Container(
      color: Colors.black,
      width: double.infinity,
      height: fixedHeight,
      child: video,
    );

    if (fixedHeight != null) return box;
    // 比例盒（竖屏顶部 / 横屏左侧由调用方控制高度）
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: box,
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
          // 横屏：左右结构，视频 | 频道列表
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: ColoredBox(
                  color: Colors.black,
                  child: _useWebEngine && _webProxyUrl != null
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            HlsWebViewPlayer(
                          key: ValueKey('web-$_webProxyUrl'),
                          proxyUrl: _webProxyUrl!,
                          onFallbackNative: () {
                            if (!mounted) return;
                            setState(() {
                              _useWebEngine = false;
                              _videoLoading = true;
                              _webProxyUrl = null;
                            });
                            final idx = _activeIdx;
                            if (idx != null) _playStreamNative(idx);
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
                        )
                      : (_videoCtrl != null && _videoCtrl!.value.isInitialized)
                          ? Stack(
                              alignment: Alignment.bottomCenter,
                              children: [
                                VideoPlayer(_videoCtrl!),
                                _ControlsBar(
                                  controller: _videoCtrl!,
                                  isLive: _isLive,
                                  onFullscreen: _enterFullscreen,
                                ),
                              ],
                            )
                          : Center(
                              child: _videoLoading
                                  ? const CircularProgressIndicator(
                                      color: Colors.white)
                                  : Text(
                                      _error ?? '选择右侧频道开始观看',
                                      style: TextStyle(
                                        color: _error != null
                                            ? Colors.orange[200]
                                            : Colors.white54,
                                      ),
                                    ),
                            ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 2,
                child: _channelList(),
              ),
            ],
          );
        }
        // 竖屏：保持原样（视频在上，列表在下）
        return Column(
          children: [
            if (_useWebEngine && _webProxyUrl != null)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      HlsWebViewPlayer(
                        key: ValueKey('webp-$_webProxyUrl'),
                        proxyUrl: _webProxyUrl!,
                        onFallbackNative: () {
                          if (!mounted) return;
                          setState(() {
                            _useWebEngine = false;
                            _videoLoading = true;
                            _webProxyUrl = null;
                          });
                          final idx = _activeIdx;
                          if (idx != null) _playStreamNative(idx);
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
                  ),
                ),
              )
            else if (_videoCtrl != null && _videoCtrl!.value.isInitialized)
              AspectRatio(
                aspectRatio: _videoCtrl!.value.aspectRatio > 0
                    ? _videoCtrl!.value.aspectRatio
                    : 16 / 9,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    VideoPlayer(_videoCtrl!),
                    _ControlsBar(
                      controller: _videoCtrl!,
                      isLive: _isLive,
                      onFullscreen: _enterFullscreen,
                    ),
                  ],
                ),
              )
            else
              Container(
                height: 220,
                color: Colors.black,
                child: Center(
                  child: _videoLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error ?? '选择下方频道开始观看',
                              style: TextStyle(
                                color: _error != null
                                    ? Colors.orange[200]
                                    : Colors.white54,
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              TextButton(
                                onPressed: _retryCurrent,
                                child: const Text('重试'),
                              ),
                            ],
                          ],
                        ),
                ),
              ),
            if (_error != null && _videoCtrl == null && _webProxyUrl == null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!,
                    style: TextStyle(color: Colors.red[400], fontSize: 12)),
              ),
            Expanded(child: _channelList()),
          ],
        );
      },
    );
  }
}


/// 流畅引擎全屏：横屏 + 沉浸式 + WebView 播放
class _FullscreenWebViewPage extends StatefulWidget {
  final String proxyUrl;
  final String title;
  const _FullscreenWebViewPage({required this.proxyUrl, required this.title});

  @override
  State<_FullscreenWebViewPage> createState() => _FullscreenWebViewPageState();
}

class _FullscreenWebViewPageState extends State<_FullscreenWebViewPage> {
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          fit: StackFit.expand,
          children: [
            HlsWebViewPlayer(proxyUrl: widget.proxyUrl),
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
                      colors: [Colors.black54, Colors.transparent],
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

// ═══ 独立全屏页面 ═══
class _FullscreenVideoPage extends StatefulWidget {
  final VideoPlayerController controller;
  final String title;
  final bool isLive;
  const _FullscreenVideoPage({
    required this.controller,
    required this.title,
    required this.isLive,
  });

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    super.dispose();
  }

  void _exit() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          children: [
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: widget.controller.value.size.width,
                  height: widget.controller.value.size.height,
                  child: VideoPlayer(widget.controller),
                ),
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
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back,
                                color: Colors.white, size: 28),
                            onPressed: _exit,
                          ),
                          Expanded(
                            child: Text(
                              widget.title,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 16),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_showControls)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: _FullscreenBar(controller: widget.controller, onExit: _exit),
                ),
              ),
          ],
        ),
      ),
    );
  }


}

// 全屏底栏：只在播放状态变化时重建，不显示读秒
class _FullscreenBar extends StatefulWidget {
  final VideoPlayerController controller;
  final VoidCallback onExit;
  const _FullscreenBar({required this.controller, required this.onExit});
  @override
  State<_FullscreenBar> createState() => _FullscreenBarState();
}

class _FullscreenBarState extends State<_FullscreenBar> {
  bool _playing = true;
  bool _buf = false;

  @override
  void initState() {
    super.initState();
    _playing = widget.controller.value.isPlaying;
    _buf = widget.controller.value.isBuffering;
    widget.controller.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    final val = widget.controller.value;
    if (mounted && (val.isPlaying != _playing || val.isBuffering != _buf)) {
      setState(() {
        _playing = val.isPlaying;
        _buf = val.isBuffering;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          if (_buf)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.6,
                  color: Colors.white,
                ),
              ),
            )
          else
            IconButton(
              icon: Icon(
                _playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 40,
              ),
              onPressed: () {
                if (_playing) {
                  widget.controller.pause();
                } else {
                  widget.controller.play();
                }
                setState(() => _playing = !_playing);
              },
            ),
          Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.redAccent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'LIVE',
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.fullscreen_exit, color: Colors.white, size: 36),
            onPressed: widget.onExit,
          ),
        ],
      ),
    );
  }
}

// ═══ 控制栏（小窗模式）═══
// 只在播放/暂停状态变化时重建，避免 ValueListenableBuilder 每帧读 position 造成卡顿
class _ControlsBar extends StatefulWidget {
  final VideoPlayerController controller;
  final bool isLive;
  final VoidCallback onFullscreen;
  const _ControlsBar({
    required this.controller,
    required this.isLive,
    required this.onFullscreen,
  });

  @override
  State<_ControlsBar> createState() => _ControlsBarState();
}

class _ControlsBarState extends State<_ControlsBar> {
  bool _playing = true;
  bool _buf = false;

  @override
  void initState() {
    super.initState();
    _playing = widget.controller.value.isPlaying;
    _buf = widget.controller.value.isBuffering;
    widget.controller.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    final val = widget.controller.value;
    if (mounted && (val.isPlaying != _playing || val.isBuffering != _buf)) {
      setState(() {
        _playing = val.isPlaying;
        _buf = val.isBuffering;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          // 缓冲中：转圈，不显示暂停
          if (_buf)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Colors.white,
                ),
              ),
            )
          else
            IconButton(
              icon: Icon(
                _playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 28,
              ),
              onPressed: () {
                if (_playing) {
                  widget.controller.pause();
                } else {
                  widget.controller.play();
                }
                setState(() => _playing = !_playing);
              },
            ),
          // LIVE 徽标紧挨播放/暂停键
          Container(
            margin: const EdgeInsets.only(left: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.redAccent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'LIVE',
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.fullscreen, color: Colors.white, size: 28),
            onPressed: widget.onFullscreen,
          ),
        ],
      ),
    );
  }
}
