# vertical_sliding_video

[中文](README.md) | [English](README.en.md)

面向竖屏短视频流的 Flutter HLS 播放器池，支持 Android 和 iOS。

## 功能

- Android Media3 ExoPlayer 播放器池
- iOS AVPlayer 播放器池
- 使用业务传入的 `cacheKey` 查找和复用播放实例
- HLS master/media playlist 解析
- playlist、加密 Key、fMP4 init map 和首个媒体分片内存预热
- 有界内存 LRU 和磁盘 LRU 缓存
- 多播放器提前 prepare，支持竖向 `PageView` 快速切换
- 相同资源的并发下载自动合并

## 安装

项目暂未发布到 pub.dev，请通过 Git 安装。在应用的 `pubspec.yaml` 中添加：

```yaml
dependencies:
  vertical_sliding_video:
    git: https://github.com/nvmms/vertical_sliding_video.git
```

然后获取依赖：

```shell
flutter pub get
```

在 Dart 文件中导入：

```dart
import 'package:vertical_sliding_video/vertical_sliding_video.dart';
```

需要锁定特定版本时，建议将 `ref` 改为 Git tag 或 commit SHA：

```yaml
dependencies:
  vertical_sliding_video:
    git:
      url: https://github.com/nvmms/vertical_sliding_video.git
      ref: your-tag-or-commit-sha
```

本地开发时也可以使用 path dependency：

```yaml
dependencies:
  vertical_sliding_video:
    path: ../vertical_sliding_video
```

## 快速开始

初始化播放器池：

```dart
await VerticalVideoPool.configure(
  maxPlayers: 3,
  memoryCacheBytes: 48 * 1024 * 1024,
  diskCacheBytes: 768 * 1024 * 1024,
);
```

定义视频资源并预热：

```dart
const source = HlsVideoSource(
  cacheKey: 'post-42-video-v3',
  url: 'https://cdn.example.com/video/master.m3u8',
  headers: {'Authorization': 'Bearer token'},
);

final localUrl = await VerticalVideoPool.preload(source);
```

`localUrl` 是当前 App 进程内可访问的标准 HTTP HLS 地址，可以交给本包或其他
HLS 播放器。内置播放器只接收该本地地址：

```dart
class VideoItemState extends State<VideoItem> {
  VerticalVideoController? controller;

  @override
  void initState() {
    super.initState();
    initializePlayer();
  }

  Future<void> initializePlayer() async {
    final value = await VerticalVideoPool.acquire(
      widget.localUrl,
      autoPlay: widget.autoPlay,
    );
    if (!mounted) {
      await value.release();
      return;
    }
    setState(() => controller = value);
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = controller;
    if (value == null) {
      return const ColoredBox(color: Colors.black);
    }
    return VerticalVideoPlayer(controller: value);
  }
}
```

业务组件不需要从其他页面传递 controller：

```dart
final controller = await VerticalVideoPool.acquire(localUrl);
```

如果同一 `cacheKey` 对应的播放器仍在池中，将返回同一个原生播放实例并增加
租约计数，因此可以保留播放位置、解码器状态和已经缓冲的数据。每次
`acquire()` 都必须对应一次 `release()` 或 `dispose()`：

```dart
await controller.release();
```

## 播放实例的生命周期

播放器池是有上限的。播放器没有租约后会留在空闲池中等待复用：

```text
acquire(localUrl)
  → 命中相同 localUrl：返回现有播放实例
  → 未命中：获取空闲实例或创建新实例

release()
  → 租约减一
  → 租约归零：暂停并进入空闲池

池已满且需要播放其他视频
  → 淘汰最久未使用的空闲实例
```

如果某个空闲实例已经被其他视频复用，再次使用旧 `cacheKey` 时会获得一个
新的播放实例，旧播放位置不会保留，但内存或磁盘中的媒体缓存仍然可以继续
命中。

池中所有实例都还有有效租约时，新的不同 `cacheKey` 无法占用播放器。业务
组件应在不再显示或不再需要预备播放时及时释放 controller。

## cacheKey

`cacheKey` 由业务方传入，用于：

- 隔离该视频的 HLS 资源缓存
- 合并相同资源的并发请求
- 在签名 URL 更新后继续命中相同 playlist 和分片

视频内容、转码版本或鉴权身份发生变化时，应更换 key，例如：

```text
post-42-video-v3
```

签名 URL 中只有过期时间变化，而实际媒体内容没有变化时，可以继续使用稳定
的业务 key，不要直接把完整签名 URL 当作 `cacheKey`。

## HLS 缓存

`preload()` 会优先准备：

- master/media playlist
- 加密 Key
- fMP4 init map
- 第一个媒体分片

代理会将 playlist 中的所有资源改写为 loopback URL。实际播放期间只有播放器
请求到后续分片时才会下载，读取顺序为内存、磁盘、网络。资源键由稳定
`cacheKey` 和不含签名参数的资源路径组成。

预加载多码率 master playlist 时，目前选择第一条 variant 预热。实际播放仍
由 Android Media3 或 iOS AVPlayer 进行码率选择，运行时选择的 variant 也会
正常写入磁盘缓存。

## 平台

### Android

使用 Media3 ExoPlayer 播放 Dart 缓存代理提供的本地 HLS 地址。
代理只绑定 `127.0.0.1`，但 Android 9（API 28）及以上默认可能禁止 HTTP，
因此宿主 App 必须允许本地代理使用明文 HTTP。

1. 新建 `android/app/src/main/res/xml/network_security_config.xml`：

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
  <base-config cleartextTrafficPermitted="true" />
</network-security-config>
```

2. 修改 `android/app/src/main/AndroidManifest.xml` 的 `<application>`：

```xml
<application
    android:name="${applicationName}"
    android:usesCleartextTraffic="true"
    android:networkSecurityConfig="@xml/network_security_config"
    ...>
```

同时确认 manifest 中存在网络权限：

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

如果宿主没有自定义 `networkSecurityConfig`，插件 manifest 中的
`usesCleartextTraffic="true"` 通常已经足够；仍建议显式采用以上配置，避免
宿主或其他依赖合并 manifest 后覆盖策略。该配置允许 App 内的 HTTP 请求，
本包代理本身只监听 loopback，不会暴露到局域网。example 已包含完整配置。

### iOS

最低支持 iOS 13.0，使用 AVPlayer 播放原生缓存代理提供的本地 HLS 地址。
代理只监听 `127.0.0.1`。在宿主的 `ios/Runner/Info.plist` 中，把下面内容加入
顶层 `<dict>`；如果已经存在 `NSAppTransportSecurity`，请合并子项，不要创建
第二个同名 key：

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoadsForMedia</key>
  <true/>
  <key>NSAllowsLocalNetworking</key>
  <true/>
</dict>
```

修改后需要停止正在运行的 App 并重新执行 `flutter run`，hot reload 不会重新
加载原生网络安全配置。`NSAllowsLocalNetworking` 允许 loopback 连接，
`NSAllowsArbitraryLoadsForMedia` 允许 AVPlayer 加载代理返回的 HTTP HLS 资源。

## Example

example 中的 `PostVideoItem` 和 `VerticalFeedVideoItem` 都是独立的
`StatefulWidget`，各自通过 `initState` 和 `dispose` 管理 controller：

```shell
cd example
flutter run --dart-define=VOD_AUTH_KEY=your-private-key
```
