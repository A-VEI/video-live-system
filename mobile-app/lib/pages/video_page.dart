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
  bool _isFullscreen = false;

  @override
  void initState() {
    super.initState();
    _loadStreams();
  }

  @override
  void dispose() {
    _videoCtrl?.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
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

  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    // 全屏模式
    if (_isFullscreen && _videoCtrl != null && _videoCtrl!.value.isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: () {}, // 防止误触退出
          child: Stack(
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: _videoCtrl!.value.aspectRatio,
                  child: VideoPlayer(_videoCtrl!),
                ),
              ),
              // 退出全屏按钮
              Positioned(
                top: 16,
                right: 16,
                child: SafeArea(
                  child: IconButton(
                    icon: const Icon(Icons.fullscreen_exit, color: Colors.white, size: 32),
                    onPressed: _toggleFullscreen,
                  ),
                ),
              ),
              // 播放控制
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _ControlsBar(
                  controller: _videoCtrl!,
                  onFullscreen: _toggleFullscreen,
                  isFullscreen: true,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 正常模式
    return Column(
      children: [
        // 视频区
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
                  onFullscreen: _toggleFullscreen,
                  isFullscreen: false,
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

        // 频道列表
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

class _ControlsBar extends StatelessWidget {
  final VideoPlayerController controller;
  final VoidCallback onFullscreen;
  final bool isFullscreen;
  const _ControlsBar({
    required this.controller,
    required this.onFullscreen,
    required this.isFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, VideoPlayerValue value, child) {
        return Container(
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: isFullscreen ? 36 : 28,
                ),
                onPressed: () {
                  value.isPlaying ? controller.pause() : controller.play();
                },
              ),
              Expanded(
                child: Text(
                  '${_format(value.position)} / ${_format(value.duration)}',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isFullscreen ? 14 : 12,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  color: Colors.white,
                  size: isFullscreen ? 36 : 28,
                ),
                onPressed: onFullscreen,
              ),
            ],
          ),
        );
      },
    );
  }

  String _format(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
