# hls_cache_player

[中文](README.md) | [English](README.en.md)

A pooled HLS video player for vertical Flutter feeds, with Android and iOS
support.

## Features

- Media3 ExoPlayer pool on Android
- AVPlayer pool on iOS
- Player lookup and reuse through an application-provided `cacheKey`
- HLS master and media playlist parsing
- In-memory preloading of playlists, encryption keys, fMP4 init maps, and the
  first media segment
- Bounded in-memory and on-disk LRU caches
- Pre-prepared players for fast vertical `PageView` transitions
- Coalescing of concurrent requests for the same resource

## Installation

The package has not been published to pub.dev yet. Install it from Git by
adding the following dependency to your application's `pubspec.yaml`:

```yaml
dependencies:
  hls_cache_player:
    git: https://github.com/nvmms/hls_cache_player.git
```

Fetch the dependency:

```shell
flutter pub get
```

Import the package:

```dart
import 'package:hls_cache_player/hls_cache_player.dart';
```

For reproducible builds, replace `main` with a Git tag or commit SHA:

```yaml
dependencies:
  hls_cache_player:
    git:
      url: https://github.com/nvmms/hls_cache_player.git
      ref: your-tag-or-commit-sha
```

Use a path dependency for local development:

```yaml
dependencies:
  hls_cache_player:
    path: ../hls_cache_player
```

## Getting started

Configure the process-wide player pool:

```dart
await HlsCachePlayerPool.configure(
  maxPlayers: 3,
  memoryCacheBytes: 48 * 1024 * 1024,
  diskCacheBytes: 768 * 1024 * 1024,
);
```

Define and preload an HLS source:

```dart
const source = HlsVideoSource(
  cacheKey: 'post-42-video-v3',
  url: 'https://cdn.example.com/video/master.m3u8',
  headers: {'Authorization': 'Bearer token'},
);

final localUrl = await HlsCachePlayerPool.preload(source);
```

`localUrl` is a standard loopback HTTP HLS URL available within the current
app process. It can be used by this package or another HLS player:

```dart
class VideoItemState extends State<VideoItem> {
  HlsPlayerController? controller;

  @override
  void initState() {
    super.initState();
    initializePlayer();
  }

  Future<void> initializePlayer() async {
    final value = await HlsCachePlayerPool.acquire(
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
    return HlsPlayerView(controller: value);
  }
}
```

Application widgets do not need to pass a controller between routes:

```dart
final controller = await HlsCachePlayerPool.acquire(localUrl);
```

If a player for the same `cacheKey` is still present in the pool, `acquire()`
returns the same native playback instance and increments its lease count. This
preserves its playback position, decoder state, and buffered media. Every
successful `acquire()` must be paired with one `release()` or `dispose()`:

```dart
await controller.release();
```

## Player lifecycle

The player pool has a fixed upper bound. A player remains idle in the pool
after its final lease is released:

```text
acquire(localUrl)
  → Matching localUrl: return the existing player
  → No match: use an idle player or create a new one

release()
  → Decrement the lease count
  → No leases left: pause the player and place it in the idle pool

Pool full and another video is requested
  → Reuse the least recently used idle player
```

If an idle player has already been reused for another video, acquiring its old
`cacheKey` creates or reuses a different player. Its previous playback
position is no longer available, but media stored in the memory or disk cache
can still be used.

When every player in the pool has an active lease, a new, different
`cacheKey` cannot acquire a slot. Widgets must release controllers when they
are no longer visible or no longer need to remain prepared.

## cacheKey

The application supplies `cacheKey`. It is used to:

- Namespace the video's HLS cache resources
- Coalesce concurrent requests for the same resource
- Reuse playlists and segments after signed URLs are refreshed

Change the key when the media contents, transcoding version, or authorization
identity changes. For example:

```text
post-42-video-v3
```

When only the expiration value in a signed URL changes and the media itself
remains the same, continue using a stable application key. Do not use the full
signed URL as `cacheKey`.

## HLS caching

`preload()` prepares the following startup resources:

- Master or media playlist
- Encryption key
- fMP4 init map
- First media segment

All playlist resources are rewritten to loopback URLs. Subsequent segments are
downloaded only when requested by the player. The lookup order is memory, disk,
and then network. Resource identity combines the stable `cacheKey` with the
resource path while deliberately excluding signed query parameters.

For a multivariant master playlist, the preloader currently warms the first
variant. Media3 on Android and AVPlayer on iOS still perform the actual
adaptive variant selection. Resources from the selected runtime variant are
also written to the disk cache.

## Platforms

### Android

Android uses Media3 ExoPlayer to play the local HLS URL exposed by the Dart
cache proxy. The proxy binds only to `127.0.0.1`, but Android 9 (API 28) and
later may reject HTTP by default. The host app must allow cleartext HTTP for
the local proxy.

1. Create `android/app/src/main/res/xml/network_security_config.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
  <base-config cleartextTrafficPermitted="true" />
</network-security-config>
```

2. Update `<application>` in `android/app/src/main/AndroidManifest.xml`:

```xml
<application
    android:name="${applicationName}"
    android:usesCleartextTraffic="true"
    android:networkSecurityConfig="@xml/network_security_config"
    ...>
```

Also ensure the manifest contains:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

If the host does not declare a custom Network Security Config, the plugin's
`usesCleartextTraffic="true"` is normally sufficient. Explicit host
configuration is still recommended so manifest merging cannot replace the
policy. This permits HTTP requests within the app; the package proxy itself
only listens on loopback and is not exposed to the LAN. The example contains
the complete configuration.

### iOS

The minimum supported version is iOS 13.0. AVPlayer plays the local HLS URL
exposed by the native cache proxy.
In the host's `ios/Runner/Info.plist`, add the following inside the top-level
`<dict>`. If `NSAppTransportSecurity` already exists, merge these child keys
instead of adding a second key with the same name:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoadsForMedia</key>
  <true/>
  <key>NSAllowsLocalNetworking</key>
  <true/>
</dict>
```

Stop the running app and run `flutter run` again after this change; hot reload
does not reload native network security settings. `NSAllowsLocalNetworking`
allows the loopback connection, while `NSAllowsArbitraryLoadsForMedia` allows
AVPlayer to load HTTP HLS resources returned by the proxy.

## Example

In the example app, `PostVideoItem` and `VerticalFeedVideoItem` are independent
`StatefulWidget` components. Each component manages its own controller through
`initState` and `dispose`:

```shell
cd example
flutter run --dart-define=VOD_AUTH_KEY=your-private-key
```
