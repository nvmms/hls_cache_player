import 'package:flutter/material.dart';
import 'package:hls_cache_player/hls_cache_player.dart';
import 'package:preload_page_view/preload_page_view.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// One player is shared by the page; the application owns its queue policy.
class PooledPostListPage extends StatefulWidget {
  const PooledPostListPage({required this.videos, super.key});
  final List<HlsVideoSource> videos;

  @override
  State<PooledPostListPage> createState() => _PooledPostListPageState();
}

class _PooledPostListPageState extends State<PooledPostListPage> {
  HlsPlayerController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      await HlsCachePlayerPool.configure();
      final urls = await HlsCachePlayerPool.preloadAll(widget.videos);
      final controller = await HlsCachePlayerPool.createController();
      await controller.insertAll([
        for (var i = 0; i < widget.videos.length; i++)
          HlsQueueItem(mediaId: widget.videos[i].cacheKey, url: urls[i]),
      ]);
      if (!mounted) return controller.release();
      setState(() => _controller = controller);
    } catch (error, stackTrace) {
      debugPrint('视频初始化失败：$error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _openFeed(int index) async {
    final controller = _controller;
    if (controller == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => VerticalFeedPage(
        videos: widget.videos,
        controller: controller,
        initialPage: index,
      ),
    ));
    await controller.pause();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error case final error?) {
      return Scaffold(body: Center(child: Text('初始化失败：$error')));
    }
    if (_controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Post 列表')),
      body: ListView.builder(
        itemCount: widget.videos.length,
        itemBuilder: (context, index) => ListTile(
          leading: const Icon(Icons.play_circle_outline),
          title: Text('视频 ${index + 1}'),
          subtitle: Text(widget.videos[index].cacheKey),
          onTap: () => _openFeed(index),
        ),
      ),
    );
  }
}

class VerticalFeedPage extends StatefulWidget {
  const VerticalFeedPage({
    required this.videos,
    required this.controller,
    required this.initialPage,
    super.key,
  });
  final List<HlsVideoSource> videos;
  final HlsPlayerController controller;
  final int initialPage;

  @override
  State<VerticalFeedPage> createState() => _VerticalFeedPageState();
}

class _VerticalFeedPageState extends State<VerticalFeedPage> {
  late final PreloadPageController _pages =
      PreloadPageController(initialPage: widget.initialPage);
  int? _requestedIndex;

  int currentIndex = 0;

  @override
  void initState() {
    super.initState();
    // _play(widget.initialPage);
  }

  Future<void> _play(int index) async {
    if (_requestedIndex == index) return;
    _requestedIndex = index;
    try {
      await widget.controller.playMedia(widget.videos[index].cacheKey);
    } catch (_) {
      if (_requestedIndex == index) _requestedIndex = null;
      rethrow;
    }
  }

  @override
  void dispose() {
    widget.controller.pause();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PreloadPageView.builder(
        controller: _pages,
        scrollDirection: Axis.vertical,
        preloadPagesCount: 1,
        itemCount: widget.videos.length,
        itemBuilder: (context, index) {
          return VisibilityDetector(
            key: Key('my-widget-key-$index'),
            onVisibilityChanged: (visibilityInfo) {
              if (visibilityInfo.visibleFraction >= 1) {
                _play(index);
                setState(() {
                  currentIndex = index;
                });
              }
            },
            child: Stack(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300), // 控制淡出速度
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                    // 自定义淡入淡出曲线
                    return FadeTransition(
                      opacity: animation,
                      child: child,
                    );
                  },
                  child: (currentIndex != index)
                      ? Container(
                          key: const ValueKey('visible'),
                          color: Colors.amber,
                        )
                      : HlsPlayerView(controller: widget.controller),
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
                    child: Text(
                      '视频 ${index + 1}\n${widget.videos[index].cacheKey}',
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ),
                )
              ],
            ),
          );
        },
      ),
    );
  }
}
