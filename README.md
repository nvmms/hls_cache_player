# vertical_sliding_video

面向竖屏短视频流的 Flutter HLS 播放器池，支持 Android 和 iOS。

## 能力

- Media3 ExoPlayer 有界播放器池
- 使用业务传入的 `cacheKey` 管理同一视频的缓存命名空间
- HLS master/media playlist 解析
- playlist、加密 Key、fMP4 init map 和首个媒体分片内存预热
- 内存 LRU 与 Media3 `SimpleCache` 磁盘 LRU
- 同一个 controller 在列表页和竖屏页之间转移，保留播放位置及缓冲
- 多播放器提前 prepare，支持竖向 `PageView` 快速切换
- iOS 使用 AVAssetResourceLoader 重写 HLS 资源请求，使 playlist、Key、
  init map 和媒体分片经过统一缓存

## 快速开始

```dart
await VerticalVideoPool.configure(
  maxPlayers: 3,
  memoryCacheBytes: 48 * 1024 * 1024,
  diskCacheBytes: 768 * 1024 * 1024,
);

const source = HlsVideoSource(
  cacheKey: 'post-42-video-v3',
  url: 'https://cdn.example.com/video/master.m3u8',
  headers: {'Authorization': 'Bearer token'},
);

await VerticalVideoPool.preload(source);
final controller = await VerticalVideoPool.acquire(
  source,
  autoPlay: true,
);
```

显示播放器：

```dart
VerticalVideoPlayer(controller: controller)
```

进入新页面时直接传递同一个 `controller`。不要在旧页面退出前销毁它：

```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => FullscreenPage(controller: controller),
  ),
);
```

不再使用播放器时释放租约：

```dart
await controller.release();
```

## cacheKey

`cacheKey` 由业务方传入，并作为一条视频所有 HLS 资源的缓存命名空间。视频内容或转码版本变化时必须更换 key，例如：

```text
post-42-video-v3
```

不同鉴权身份能够获取不同媒体内容时，也应把身份或内容版本包含在 key 中。

## Android 验证

运行示例：

```shell
cd example
flutter run
```

示例会预热三个 HLS 视频并提前申请三个播放器。列表首条正在播放时，点击进入竖屏会继续使用同一个原生播放器；上下滑动会切换到已 prepare 的相邻播放器。

当前 HLS 预加载器面向常规 VOD playlist。预加载多码率 master playlist 时
暂时选择第一条 variant；实际播放仍由 Android Media3 或 iOS AVPlayer
进行码率选择，所选 variant 的运行时请求会正常写入磁盘缓存。

## iOS

iOS 最低版本为 13.0，使用 AVPlayer 和 AVAssetResourceLoader。Flutter API
与 Android 完全相同，不需要平台分支：

```dart
final controller = await VerticalVideoPool.acquire(source, autoPlay: true);
```

播放器收到原始 HLS 地址后，会将 playlist 中的 variant、Key、init map、
字幕和媒体分片 URL 重写为内部 `vsv-cache` 协议。资源读取顺序为内存、
磁盘、网络，网络响应会同时进入缓存。
