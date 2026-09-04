# hls_cache_player

面向竖屏短视频流的 Flutter HLS 播放插件，支持 Android 和 iOS。

- 一个长期存活的原生播放器
- 一个固定的 Texture / Surface
- 由目标 App 管理的动态媒体队列
- HLS playlist、首片及后续分片的内存/磁盘缓存
- Android Media3 `DefaultPreloadManager`
- iOS AVPlayer 播放会话

## 初始化与缓存

```dart
await HlsCachePlayerPool.configure(
  memoryCacheBytes: 48 * 1024 * 1024,
  diskCacheBytes: 768 * 1024 * 1024,
);

final localUrl = await HlsCachePlayerPool.preload(
  const HlsVideoSource(
    cacheKey: 'video-1-v1',
    url: 'https://example.com/video-1/master.m3u8',
  ),
);
```

`preload()` 返回本进程的 loopback URL。队列只能插入这个本地地址，播放器
通过本地代理读取已经缓存的数据，并按需请求尚未缓存的分片。

## 单播放器队列

播放器会话只创建一次：

```dart
final controller = await HlsCachePlayerPool.createController();
```

目标 App 决定何时插入、删除以及播放哪一项：

```dart
await controller.insertAll([
  HlsQueueItem(mediaId: 'video-1', url: localUrl1),
  HlsQueueItem(mediaId: 'video-2', url: localUrl2),
]);

await controller.insert(
  HlsQueueItem(mediaId: 'video-3', url: localUrl3),
  index: 1,
);

await controller.playMedia('video-2');
await controller.remove('video-1');
await controller.removeAll(['video-2', 'video-3']);
```

`mediaId` 必须在当前队列中唯一。业务代码应使用稳定 `mediaId`，不要持久化
数组索引；插入和删除会改变索引。

Android 的业务队列会同步给 `DefaultPreloadManager`。当前项及相邻一项预加载
3 秒 Sample。播放时使用预热管理器返回的同一份 MediaSource，因此已经解析的
SampleQueue 可以直接交给播放器。视频切换不会销毁 Player、Surface 或 Texture。

## 显示与状态

```dart
HlsPlayerView(controller: controller)
```

```dart
controller.states.listen((value) {
  print(value.mediaId);
  print(value.mediaIndex);
  print(value.position);
  print(value.duration);
  print(value.bufferedPosition);
  print(value.cacheProgress);
});
```

`cacheProgress` 由本地 HLS 代理根据缓存中的媒体分片及 playlist 的 `EXTINF`
时长计算；`bufferedPosition` 表示原生播放器当前可播放窗口，两者含义不同。

## 生命周期

队列项的窗口策略完全由目标 App 管理。插件不会自动添加或淘汰业务视频。

退出播放页面或结束播放会话时：

```dart
await controller.release();
```

这会释放播放器、Surface 和 Texture。应用不再使用缓存代理时可统一关闭：

```dart
await HlsCachePlayerPool.dispose();
```

同步的 Flutter `State.dispose()` 中也可以调用 `controller.dispose()`；需要等待
原生资源确实释放完成时，优先使用异步 `release()`。
