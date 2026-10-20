import 'package:flutter/material.dart';
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
        // 视频播放区
        if (_videoCtrl != null && _videoCtrl!.value.isInitialized)
          AspectRatio(
            aspectRatio: _videoCtrl!.value.aspectRatio > 0
                ? _videoCtrl!.value.aspectRatio
                : 16 / 9,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                VideoPlayer(_videoCtrl!),
                _ControlsBar(controller: _videoCtrl!),
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
  const _ControlsBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, VideoPlayerValue value, child) {
        return Container(
          color: Colors.black38,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: () {
                  value.isPlaying ? controller.pause() : controller.play();
                },
              ),
              Expanded(
                child: Text(
                  '${_format(value.position)} / ${_format(value.duration)}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
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
