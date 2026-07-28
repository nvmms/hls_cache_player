import 'package:flutter/material.dart';
import 'package:vertical_sliding_video/vertical_sliding_video.dart';

/// Example feed that keeps at most three native player leases.
class PooledPostListPage extends StatefulWidget {
  const PooledPostListPage({required this.videos, super.key});

  final List<HlsVideoSource> videos;

  @override
  State<PooledPostListPage> createState() => _PooledPostListPageState();
}

class _PooledPostListPageState extends State<PooledPostListPage> {
  final Map<int, VerticalVideoController> _controllers = {};
  Future<void> _windowOperation = Future<void>.value();
  Object? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      await VerticalVideoPool.configure(maxPlayers: 3);
      await VerticalVideoPool.preloadAll(widget.videos);
      await _ensureWindow(0);
      await _controllers[0]!.play();
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _ensureWindow(int center) {
    _windowOperation = _windowOperation.then((_) => _applyWindow(center));
    return _windowOperation;
  }

  Future<void> _applyWindow(int center) async {
    final wanted = _windowIndices(center);

    // Release stale leases first so the native pool has free slots.
    final stale = _controllers.keys
        .where((index) => !wanted.contains(index))
        .toList(growable: false);
    for (final index in stale) {
      final controller = _controllers.remove(index);
      if (controller != null) await controller.release();
    }

    for (final index in wanted) {
      if (_controllers.containsKey(index)) continue;
      _controllers[index] = await VerticalVideoPool.acquire(
        widget.videos[index],
      );
    }
    if (mounted) setState(() {});
  }

  Set<int> _windowIndices(int center) {
    final wanted = <int>{center};
    for (var distance = 1; wanted.length < 3; distance++) {
      final next = center + distance;
      final previous = center - distance;
      if (next < widget.videos.length) wanted.add(next);
      if (wanted.length < 3 && previous >= 0) wanted.add(previous);
      if (next >= widget.videos.length && previous < 0) break;
    }
    return wanted;
  }

  Future<void> _activate(int index) async {
    await _ensureWindow(index);
    for (final entry in _controllers.entries) {
      if (entry.key == index) {
        await entry.value.play();
      } else {
        await entry.value.pause();
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
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
        itemBuilder: (context, index) => GestureDetector(
          onTap: () async {
            await _activate(index);
            if (!context.mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _PooledVerticalFeedPage(
                  videos: widget.videos,
                  controllers: _controllers,
                  initialPage: index,
                  ensureWindow: _ensureWindow,
                ),
              ),
            );
            if (mounted) setState(() {});
          },
          child: SizedBox(
            height: 280,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_controllers[index] case final controller?)
                  VerticalVideoPlayer(controller: controller)
                else
                  const ColoredBox(color: Color(0xff202020)),
                Positioned(
                  left: 16,
                  bottom: 16,
                  child: Text('视频 ${index + 1} · 点击进入竖屏'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PooledVerticalFeedPage extends StatefulWidget {
  const _PooledVerticalFeedPage({
    required this.videos,
    required this.controllers,
    required this.initialPage,
    required this.ensureWindow,
  });

  final List<HlsVideoSource> videos;
  final Map<int, VerticalVideoController> controllers;
  final int initialPage;
  final Future<void> Function(int index) ensureWindow;

  @override
  State<_PooledVerticalFeedPage> createState() =>
      _PooledVerticalFeedPageState();
}

class _PooledVerticalFeedPageState
    extends State<_PooledVerticalFeedPage> {
  late final PageController _pageController = PageController(
    initialPage: widget.initialPage,
  );

  Future<void> _activate(int index) async {
    await widget.ensureWindow(index);
    for (final entry in widget.controllers.entries) {
      if (entry.key == index) {
        await entry.value.play();
      } else {
        await entry.value.pause();
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        itemCount: widget.videos.length,
        onPageChanged: _activate,
        itemBuilder: (context, index) {
          final controller = widget.controllers[index];
          return Stack(
            fit: StackFit.expand,
            children: [
              if (controller != null)
                VerticalVideoPlayer(controller: controller)
              else
                const ColoredBox(
                  color: Colors.black,
                  child: Center(child: CircularProgressIndicator()),
                ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 40,
                child: Text(
                  '视频 ${index + 1}\n'
                  'cacheKey: ${widget.videos[index].cacheKey}',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
