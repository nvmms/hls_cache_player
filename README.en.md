# vertical_sliding_video

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
  vertical_sliding_video:
    git: https://github.com/nvmms/vertical_sliding_video.git
```

Fetch the dependency:

```shell
flutter pub get
```

Import the package:

```dart
import 'package:vertical_sliding_video/vertical_sliding_video.dart';
```

For reproducible builds, replace `main` with a Git tag or commit SHA:

```yaml
dependencies:
  vertical_sliding_video:
    git:
      url: https://github.com/nvmms/vertical_sliding_video.git
      ref: your-tag-or-commit-sha
```

Use a path dependency for local development:

```yaml
dependencies:
  vertical_sliding_video:
    path: ../vertical_sliding_video
```

## Getting started

Configure the process-wide player pool:

```dart
await VerticalVideoPool.configure(
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

await VerticalVideoPool.preload(source);
```

Any widget can acquire the playback instance associated with the same
`cacheKey`:

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
      widget.source,
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

Application widgets do not need to pass a controller from one route to
another. The pool looks up an existing native player by `cacheKey`:

```dart
final controller = await VerticalVideoPool.acquire(source);
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
acquire(cacheKey)
  → Matching cacheKey: return the existing player
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

- Find an existing player for the same video
- Namespace the video's HLS cache resources
- Coalesce concurrent requests for the same resource

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

Subsequent segments requested during playback go through the same cache layer.
The lookup order is memory, disk, and then network.

For a multivariant master playlist, the preloader currently warms the first
variant. Media3 on Android and AVPlayer on iOS still perform the actual
adaptive variant selection. Resources from the selected runtime variant are
also written to the disk cache.

## Platforms

### Android

The Android implementation uses Media3 ExoPlayer, `SimpleCache`, and a custom
memory-first `DataSource`.

### iOS

The minimum supported version is iOS 13.0. The implementation uses AVPlayer
and AVAssetResourceLoader. Variant playlists, encryption keys, init maps,
subtitles, and media segment URLs are rewritten to an internal caching
protocol.

## Example

In the example app, `PostVideoItem` and `VerticalFeedVideoItem` are independent
`StatefulWidget` components. Each component manages its own controller through
`initState` and `dispose`:

```shell
cd example
flutter run --dart-define=VOD_AUTH_KEY=your-private-key
```
