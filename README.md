# hls_cache_player

跨 Android/iOS 的单实例 HLS 播放器，支持内存/磁盘缓存、playlist 和原地换源。

播放器、Android `Texture` 与 iOS 播放视图只创建一次。`addSource` 将媒体加入
playlist；`moveTo(mediaId)` 或 `play(mediaId)` 选择列表项；`changeSource`
用于非 playlist 场景，直接替换底层播放链接并保留播放器和渲染对象。

```dart
final player = await HlsCachePlayer.create();

final episode1Url = await HlsCacheProxy.preload(const HlsVideoSource(
  cacheKey: 'episode-1', // 同时作为 mediaId
  url: 'https://example.com/1.m3u8',
));
final episode2Url = await HlsCacheProxy.preload(const HlsVideoSource(
  cacheKey: 'episode-2',
  url: 'https://example.com/2.m3u8',
));

// 播放器操作不再触发预加载。
await player.addSource(mediaId: 'episode-1', playbackUrl: episode1Url);
await player.addSource(mediaId: 'episode-2', playbackUrl: episode2Url);

// 重复 mediaId 会输出警告并被忽略，不会抛出异常。
// addSource 仅登记列表项；此时原生播放器不会 prepare 或加载媒体。

await player.moveTo('episode-2');
await player.play();
// 或：await player.play('episode-1');
// 当前视频结束后会暂停，不会自动连续播放下一项。

// 非列表换源：playerId / Texture / PlatformView 保持不变。
final liveUrl = await HlsCacheProxy.preload(const HlsVideoSource(
  cacheKey: 'live',
  url: 'https://example.com/live.m3u8',
));
await player.changeSource(mediaId: 'live', playbackUrl: liveUrl);
```

ListView 中可以按 mediaId 独立监听状态：

```dart
StreamBuilder<VideoPlayerValue>(
  stream: player.statesOf(mediaId),
  initialData: player.stateOf(mediaId),
  builder: (context, snapshot) {
    final state = snapshot.data;
    if (state == null) return const SizedBox.shrink();
    return Text(state.isPlaying ? '播放中' : '未播放');
  },
)
```

`stateOf(mediaId)` 在媒体尚未通过 `addSource` 添加时返回 `null`；已添加但尚未播放
时返回 idle 状态。

使用 `HlsPlayerView(controller: player)` 渲染。应用退出或确定不再使用播放器时调用
`await HlsCachePlayer.dispose()`。
播放器和代理生命周期相互独立；只有整个 HLS 缓存代理确定不再使用时，才调用
`await HlsCacheProxy.dispose()`。关闭代理会使之前返回的所有本地 URL 失效。
`cacheKey` 必须非空，在 playlist 内同时承担唯一 `mediaId`。`changeSource` 会退出
playlist 模式，因此之后 `player.playList` 为空；再次调用 `addSource` 会建立新列表。
