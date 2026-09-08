# hls_cache_player

跨 Android/iOS 的单实例 HLS 播放器，支持内存/磁盘缓存、playlist 和原地换源。

播放器、Android `Texture` 与 iOS 播放视图只创建一次。`addSource` 将媒体加入
playlist；`moveTo(index)` 或 `play(mediaId)` 选择并播放列表项；`changeSource`
用于非 playlist 场景，直接替换底层播放链接并保留播放器和渲染对象。

```dart
final player = await HlsCachePlayer.create();

await player.addSource(const HlsVideoSource(
  cacheKey: 'episode-1', // 同时作为 mediaId
  url: 'https://example.com/1.m3u8',
));
await player.addSource(const HlsVideoSource(
  cacheKey: 'episode-2',
  url: 'https://example.com/2.m3u8',
));

await player.moveTo(1);
await player.play();
// 或：await player.play('episode-1');

// 非列表换源：playerId / Texture / PlatformView 保持不变。
await player.changeSource(const HlsVideoSource(
  cacheKey: 'live',
  url: 'https://example.com/live.m3u8',
));
```

使用 `HlsPlayerView(controller: player)` 渲染。应用退出或确定不再使用播放器时调用
`await HlsCachePlayer.dispose()`。
`cacheKey` 必须非空，在 playlist 内同时承担唯一 `mediaId`。`changeSource` 会退出
playlist 模式，因此之后 `player.playList` 为空；再次调用 `addSource` 会建立新列表。
