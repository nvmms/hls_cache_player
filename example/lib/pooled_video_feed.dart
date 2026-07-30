import 'package:flutter/material.dart';
import 'package:preload_page_view/preload_page_view.dart';
import 'package:vertical_sliding_video/vertical_sliding_video.dart';

/// The list owns no video controllers. Every visible post item independently
/// acquires and releases its controller with its widget lifecycle.
class PooledPostListPage extends StatefulWidget {
  const PooledPostListPage({required this.videos, super.key});

  final List<HlsVideoSource> videos;

  @override
  State<PooledPostListPage> createState() => _PooledPostListPageState();
}

class _PooledPostListPageState extends State<PooledPostListPage> {
  final Map<int, GlobalKey<PostVideoItemState>> _itemKeys = {};
  Object? _error;
  bool _ready = false;
  bool _feedOpen = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      // A list can transiently have more than three mounted children because
      // ListView keeps a small cache extent. Feed pages normally use at most 3.
      await VerticalVideoPool.configure(maxPlayers: 4);
      await VerticalVideoPool.preloadAll(widget.videos);
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  GlobalKey<PostVideoItemState> _keyFor(int index) {
    return _itemKeys.putIfAbsent(index, () => GlobalKey<PostVideoItemState>());
  }

  Future<void> _openFeed(int index) async {
    // The list route remains mounted underneath the new route. Explicitly ask
    // its mounted children to return their leases before the feed acquires its
    // current/adjacent players.
    setState(() => _feedOpen = true);
    await Future.wait(
      _itemKeys.values.map(
        (key) => key.currentState?.releaseController() ?? Future<void>.value(),
      ),
    );
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            VerticalFeedPage(videos: widget.videos, initialPage: index),
      ),
    );

    if (mounted) setState(() => _feedOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_error case final error?) {
      return Scaffold(body: Center(child: Text('初始化失败：$error')));
    }
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Post 列表')),
      body: ListView.builder(
        itemCount: widget.videos.length,
        itemBuilder: (context, index) => PostVideoItem(
          key: _keyFor(index),
          source: widget.videos[index],
          index: index,
          enabled: !_feedOpen,
          autoPlay: index == 0,
          onOpen: () => _openFeed(index),
        ),
      ),
    );
  }
}

/// One post cell owns exactly one controller lease while [enabled].
class PostVideoItem extends StatefulWidget {
  const PostVideoItem({
    required this.source,
    required this.index,
    required this.enabled,
    required this.autoPlay,
    required this.onOpen,
    super.key,
  });

  final HlsVideoSource source;
  final int index;
  final bool enabled;
  final bool autoPlay;
  final VoidCallback onOpen;

  @override
  State<PostVideoItem> createState() => PostVideoItemState();
}

class PostVideoItemState extends State<PostVideoItem> {
  VerticalVideoController? _controller;
  Future<void>? _pendingRelease;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _acquire();
  }

  @override
  void didUpdateWidget(PostVideoItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.cacheKey != widget.source.cacheKey) {
      releaseController().then((_) {
        if (mounted && widget.enabled) _acquire();
      });
    } else if (!oldWidget.enabled && widget.enabled) {
      _acquire();
    } else if (oldWidget.enabled && !widget.enabled) {
      releaseController();
    }
  }

  Future<void> _acquire() async {
    if (_controller != null || !widget.enabled) return;
    final generation = ++_generation;
    try {
      final controller = await VerticalVideoPool.acquire(
        widget.source,
        autoPlay: widget.autoPlay,
      );
      if (!mounted || !widget.enabled || generation != _generation) {
        await controller.release();
        return;
      }
      setState(() => _controller = controller);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> releaseController() async {
    if (_pendingRelease case final pending?) {
      await pending;
      return;
    }
    _generation++;
    final controller = _controller;
    _controller = null;
    if (mounted) setState(() {});
    if (controller == null) return;
    final release = controller.release();
    _pendingRelease = release;
    try {
      await release;
    } finally {
      if (identical(_pendingRelease, release)) _pendingRelease = null;
    }
  }

  @override
  void dispose() {
    _generation++;
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onOpen,
      child: SizedBox(
        height: 280,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_controller case final controller?)
              VerticalVideoPlayer(controller: controller)
            else
              const ColoredBox(color: Color(0xff202020)),
            if (_error != null) Center(child: Text('播放器初始化失败：$_error')),
            Positioned(
              left: 16,
              bottom: 16,
              child: Text('视频 ${widget.index + 1} · 点击进入竖屏'),
            ),
            if (_controller case final controller?)
              Positioned(
                left: 12,
                right: 12,
                bottom: 0,
                child: _VideoProgressBar(controller: controller),
              ),
          ],
        ),
      ),
    );
  }
}

/// The feed only owns the current index. Each PageView child independently
/// creates and disposes its native controller.
class VerticalFeedPage extends StatefulWidget {
  const VerticalFeedPage({
    required this.videos,
    required this.initialPage,
    super.key,
  });

  final List<HlsVideoSource> videos;
  final int initialPage;

  @override
  State<VerticalFeedPage> createState() => _VerticalFeedPageState();
}

class _VerticalFeedPageState extends State<VerticalFeedPage> {
  late final PageController _pageController = PageController(
    initialPage: widget.initialPage,
  );
  late int _currentIndex = widget.initialPage;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PreloadPageView.builder(
        // controller: _pageController,
        scrollDirection: Axis.vertical,
        preloadPagesCount: 1,
        // allowImplicitScrolling: true,
        itemCount: widget.videos.length,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemBuilder: (context, index) => VerticalFeedVideoItem(
          key: ValueKey(widget.videos[index].cacheKey),
          source: widget.videos[index],
          index: index,
          shouldPlay: index == _currentIndex,
        ),
      ),
    );
  }
}

/// One PageView child owns one controller from initState through dispose.
///
/// PageView.builder normally keeps the current and adjacent children mounted,
/// which naturally prepares a small player window without a controller map in
/// the parent page.
class VerticalFeedVideoItem extends StatefulWidget {
  const VerticalFeedVideoItem({
    required this.source,
    required this.index,
    required this.shouldPlay,
    super.key,
  });

  final HlsVideoSource source;
  final int index;
  final bool shouldPlay;

  @override
  State<VerticalFeedVideoItem> createState() => _VerticalFeedVideoItemState();
}

class _VerticalFeedVideoItemState extends State<VerticalFeedVideoItem> {
  VerticalVideoController? _controller;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _acquire();
  }

  @override
  void didUpdateWidget(VerticalFeedVideoItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.cacheKey != widget.source.cacheKey) {
      _replaceSource();
    } else if (oldWidget.shouldPlay != widget.shouldPlay) {
      _applyPlaybackState();
    }
  }

  Future<void> _acquire() async {
    final generation = ++_generation;
    try {
      final controller = await VerticalVideoPool.acquire(
        widget.source,
        autoPlay: widget.shouldPlay,
      );
      if (!mounted || generation != _generation) {
        await controller.release();
        return;
      }
      _controller = controller;
      await _applyPlaybackState();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _replaceSource() async {
    _generation++;
    final previous = _controller;
    _controller = null;
    if (previous != null) await previous.release();
    if (mounted) await _acquire();
  }

  Future<void> _applyPlaybackState() async {
    final controller = _controller;
    if (controller == null) return;
    if (widget.shouldPlay) {
      await controller.play();
    } else {
      await controller.pause();
    }
  }

  @override
  void dispose() {
    _generation++;
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_controller case final controller?)
          VerticalVideoPlayer(controller: controller)
        else
          const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_error != null) Center(child: Text('播放器初始化失败：$_error')),
        Positioned(
          left: 16,
          right: 16,
          bottom: 40,
          child: Text(
            '视频 ${widget.index + 1}\ncacheKey: ${widget.source.cacheKey}',
            style: const TextStyle(fontSize: 18),
          ),
        ),
        if (_controller case final controller?)
          Positioned(
            left: 12,
            right: 12,
            bottom: 8,
            child: _VideoProgressBar(controller: controller),
          ),
      ],
    );
  }
}

class _VideoProgressBar extends StatelessWidget {
  const _VideoProgressBar({required this.controller});

  final VerticalVideoController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<VideoPlayerValue>(
      stream: controller.states,
      initialData: controller.value,
      builder: (context, snapshot) {
        final value = snapshot.data ?? controller.value;
        final durationMs = value.duration.inMilliseconds;
        final positionMs = value.position.inMilliseconds.clamp(0, durationMs);

        return Row(
          children: [
            Text(
              _formatDuration(value.position),
              style: const TextStyle(fontSize: 11),
            ),
            Expanded(
              child: Slider(
                min: 0,
                max: durationMs > 0 ? durationMs.toDouble() : 1,
                value: positionMs.toDouble(),
                onChanged: durationMs > 0
                    ? (milliseconds) {
                        controller.seekTo(
                          Duration(milliseconds: milliseconds.round()),
                        );
                      }
                    : null,
              ),
            ),
            Text(
              _formatDuration(value.duration),
              style: const TextStyle(fontSize: 11),
            ),
          ],
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
