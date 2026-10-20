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

  @override
  void initState() {
    super.initState();
    _loadStreams();
  }

  @override
  void dispose() {
    _videoCtrl?.dispose();
    super.dispose();
  }

  Future<void> _loadStreams() async {
    try {
      final data = await ApiClient.instance.getStreams();
      setState(() { _streams = data; _loading = false; });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  Future<void> _playStream(int idx) async {
    if (_activeIdx == idx) return;
    setState(() {
      _activeIdx = idx;
      _videoLoading = true;
    });
    _videoCtrl?.dispose();

    final stream = _streams[idx];
    final url = ApiClient.instance.proxyUrl(stream['url']);

    try {
      final vc = VideoPlayerController.networkUrl(Uri.parse(url));
      await vc.initialize();
      await vc.play();
      setState(() {
        _videoCtrl = vc;
        _videoLoading = false;
      });
    } catch (e) {
      setState(() => _videoLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('视频加载失败: $e')),
        );
      }
    }
  }

  void _enterFullscreen() {
    if (_videoCtrl == null) return;
    // 推送独立全屏页面
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenVideoPage(controller: _videoCtrl!),
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
                _ControlsBar(
                  controller: _videoCtrl!,
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
                  : const Text('选择下方频道开始观看',
                      style: TextStyle(color: Colors.white54)),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _streams.length,
            itemBuilder: (_, i) {
              final s = _streams[i];
              final isActive = _activeIdx == i;
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
                title: Text(s['name'] ?? '',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(isActive ? '正在播放…' : '点击播放',
                    style: TextStyle(
                        fontSize: 12,
                        color: isActive
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey)),
                trailing: Icon(
                  isActive ? Icons.graphic_eq : Icons.play_circle_outline,
                  color: isActive
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                ),
                selected: isActive,
                selectedTileColor:
                    Theme.of(context).colorScheme.primary.withOpacity(0.05),
                onTap: () => _playStream(i),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ═══ 独立全屏页面 ═══
class _FullscreenVideoPage extends StatefulWidget {
  final VideoPlayerController controller;
  const _FullscreenVideoPage({required this.controller});

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    // 横屏 + 沉浸式
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    // 恢复竖屏 + 状态栏
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
            // 视频铺满全屏
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
            // 顶部退出按钮
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
                          const Text('返回',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // 底部控制栏
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
                            Text(
                              '${_fmt(value.position)} / ${_fmt(value.duration)}',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14),
                            ),
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
  final VoidCallback onFullscreen;
  const _ControlsBar({
    required this.controller,
    required this.onFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, VideoPlayerValue value, _) {
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
                child: Text(
                  '${_fmt(value.position)} / ${_fmt(value.duration)}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
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
