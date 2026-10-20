import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
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
  ChewieController? _chewieCtrl;
  bool _loading = true;
  bool _videoLoading = false;

  @override
  void initState() {
    super.initState();
    _loadStreams();
  }

  @override
  void dispose() {
    _chewieCtrl?.dispose();
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
    _chewieCtrl?.dispose();
    _videoCtrl?.dispose();

    final stream = _streams[idx];
    final url = ApiClient.instance.proxyUrl(stream['url']);

    try {
      final vc = VideoPlayerController.networkUrl(Uri.parse(url));
      await vc.initialize();
      final cc = ChewieController(
        videoPlayerController: vc,
        autoPlay: true,
        looping: true,
        showControls: true,
        allowFullScreen: true,
        allowPlaybackSpeedChanging: false,
        placeholder: Container(color: Colors.black),
      );
      setState(() {
        _videoCtrl = vc;
        _chewieCtrl = cc;
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
        if (_chewieCtrl != null)
          AspectRatio(
            aspectRatio: _videoCtrl!.value.aspectRatio > 0 ? _videoCtrl!.value.aspectRatio : 16 / 9,
            child: Chewie(controller: _chewieCtrl!),
          )
        else
          Container(
            height: 220,
            color: Colors.black,
            child: Center(
              child: _videoLoading
                ? const CircularProgressIndicator(color: Colors.white)
                : const Text('选择下方频道开始观看', style: TextStyle(color: Colors.white54)),
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
                title: Text(s['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(isActive ? '正在播放…' : '点击播放',
                  style: TextStyle(fontSize: 12,
                    color: isActive ? Theme.of(context).colorScheme.primary : Colors.grey)),
                trailing: Icon(
                  isActive ? Icons.graphic_eq : Icons.play_circle_outline,
                  color: isActive ? Theme.of(context).colorScheme.primary : Colors.grey,
                ),
                selected: isActive,
                selectedTileColor: Theme.of(context).colorScheme.primary.withOpacity(0.05),
                onTap: () => _playStream(i),
              );
            },
          ),
        ),
      ],
    );
  }
}
