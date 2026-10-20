import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../api/api_client.dart';

class VideoPage extends StatefulWidget {
  const VideoPage({super.key});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  List<dynamic> _streams = [];
  int? _activeIdx;
  VideoPlayerController? _videoCtrl;
  bool _loading = true;
  bool _videoLoading = false;
  String? _error;
  bool _isLive = true;
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    _loadStreams();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _videoCtrl?.dispose();
    super.dispose();
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

  Future<void> _playStream(int idx) async {
    if (_activeIdx == idx && _videoCtrl?.value.isPlaying == true) return;
    setState(() {
      _activeIdx = idx;
      _videoLoading = true;
      _error = null;
    });
    _liveTimer?.cancel();
    final old = _videoCtrl;
    _videoCtrl = null;
    // 先释放旧控制器，避免闪烁时并发初始化
    old?.dispose();

    final stream = _streams[idx] as Map;
    final rawProxy = (stream['proxy_url'] ?? stream['url'] ?? '') as String;
    final url = ApiClient.instance.absoluteUrl(rawProxy);

    try {
      final vc = VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      await vc.initialize();
      if (!mounted) {
        vc.dispose();
        return;
      }

      // 直播：不要 seekTo(duration-3) — live HLS 的 duration 常为 0/∞
      final d = vc.value.duration;
      final live = d.inMilliseconds <= 1 || d == Duration.zero;
      if (!live && d > const Duration(seconds: 5)) {
        // 点播/回放才允许贴边
        await vc.seekTo(d - const Duration(seconds: 3));
      }
      await vc.play();

      setState(() {
        _videoCtrl = vc;
        _videoLoading = false;
        _isLive = live;
      });

      // 定期贴直播边（仅 live），防止缓冲堆积越播越延后
      if (live) {
        _liveTimer = Timer.periodic(const Duration(seconds: 20), (_) {
          final c = _videoCtrl;
          if (c == null || !c.value.isInitialized) return;
          final pos = c.value.position;
          final dur = c.value.duration;
          if (dur.inMilliseconds > 1 && pos < dur - const Duration(seconds: 6)) {
            c.seekTo(dur - const Duration(seconds: 2));
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _videoLoading = false;
        _videoCtrl = null;
        _error = describePlayError(e);
      });
    }
  }

  Future<void> _retryCurrent() async {
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
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
        if (_videoCtrl != null && _videoCtrl!.value.isInitialized)
          AspectRatio(
            aspectRatio: _videoCtrl!.value.aspectRatio > 0
                ? _videoCtrl!.value.aspectRatio
                : 16 / 9,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                VideoPlayer(_videoCtrl!),
                if (_isLive)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'LIVE',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
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
        if (_error != null && _videoCtrl == null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!,
                style: TextStyle(color: Colors.red[400], fontSize: 12)),
          ),
        Expanded(
          child: RefreshIndicator(
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
          ),
        ),
      ],
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
                          if (widget.isLive)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('LIVE',
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 11)),
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
                  child: ValueListenableBuilder(
                    valueListenable: widget.controller,
                    builder: (context, VideoPlayerValue value, _) {
                      final label = widget.isLive
                          ? '直播中'
                          : '${_fmt(value.position)} / ${_fmt(value.duration)}';
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                value.isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.white,
                                size: 40,
                              ),
                              onPressed: () {
                                value.isPlaying
                                    ? widget.controller.pause()
                                    : widget.controller.play();
                              },
                            ),
                            Text(label,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14)),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.fullscreen_exit,
                                  color: Colors.white, size: 36),
                              onPressed: _exit,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ═══ 控制栏（小窗模式）═══
class _ControlsBar extends StatelessWidget {
  final VideoPlayerController controller;
  final bool isLive;
  final VoidCallback onFullscreen;
  const _ControlsBar({
    required this.controller,
    required this.isLive,
    required this.onFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, VideoPlayerValue value, _) {
        final label = isLive ? '直播中' : '${_fmt(value.position)} / ${_fmt(value.duration)}';
        return Container(
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 28,
                ),
                onPressed: () {
                  value.isPlaying ? controller.pause() : controller.play();
                },
              ),
              Expanded(
                child: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
              IconButton(
                icon: const Icon(Icons.fullscreen,
                    color: Colors.white, size: 28),
                onPressed: onFullscreen,
              ),
            ],
          ),
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
