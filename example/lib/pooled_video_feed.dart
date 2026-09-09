import 'package:flutter/material.dart';
import 'package:hls_cache_player/hls_cache_player.dart';

/// A feed backed by one native player and one texture/view.
class PlaylistPlayerPage extends StatefulWidget {
  const PlaylistPlayerPage({required this.videos, super.key});
  final List<HlsVideoSource> videos;

  @override
  State<PlaylistPlayerPage> createState() => _PlaylistPlayerPageState();
}

class _PlaylistPlayerPageState extends State<PlaylistPlayerPage> {
  HlsPlayerController? _player;
  Object? _error;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final playbackUrls = await HlsCacheProxy.preloadAll(widget.videos);
      final player = await HlsCachePlayer.create();
      for (var index = 0; index < widget.videos.length; index++) {
        await player.addSource(
          mediaId: widget.videos[index].cacheKey,
          playbackUrl: playbackUrls[index],
        );
      }
      if (widget.videos.isNotEmpty) {
        await player.play(mediaId: widget.videos.first.cacheKey);
      }
      if (mounted) setState(() => _player = player);
    } catch (error, stackTrace) {
      debugPrint('视频初始化失败：$error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _move(int index) async {
    final player = _player;
    if (player == null) return;
    await player.moveTo(widget.videos[index].cacheKey);
    await player.play();
    if (mounted) setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      appBar: AppBar(title: const Text('单播放器 Playlist')),
      body: _error != null
          ? Center(child: Text('初始化失败：$_error'))
          : player == null
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  Expanded(child: HlsPlayerView(controller: player)),
                  SizedBox(
                    height: 96,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.videos.length,
                      itemBuilder: (context, index) => TextButton(
                        onPressed: () => _move(index),
                        child: Text('视频 ${index + 1}',
                            style: TextStyle(
                              fontWeight: index == _index
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            )),
                      ),
                    ),
                  ),
                ]),
    );
  }
}
