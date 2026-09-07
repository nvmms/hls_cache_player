# hls_cache_player

A Flutter HLS plugin for vertical video feeds on Android and iOS.

- A new independent native player per createController call; application-owned pooling
- An independent Texture / Surface per player
- A dynamic media queue managed by the target application
- Memory and disk caching for HLS playlists and segments
- Media3 `DefaultPreloadManager` on Android
- An independent AVPlayer session per controller on iOS

## Configure and preload

```dart
await HlsCachePlayer.configure(
  memoryCacheBytes: 48 * 1024 * 1024,
  diskCacheBytes: 768 * 1024 * 1024,
);

final localUrl = await HlsCachePlayer.preload(
  const HlsVideoSource(
    cacheKey: 'video-1-v1',
    url: 'https://example.com/video-1/master.m3u8',
  ),
);
```

`preload()` returns a process-local loopback URL. Queue entries accept this
local URL so playback reads cached data through the proxy and fetches missing
segments on demand.

## Independent players and queues

Every call creates a new controller and native player. The application owns reuse and pooling:

```dart
final controller = await HlsCachePlayer.createController();
```

The target application decides when to insert, remove, and select entries:

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

`mediaId` must be unique in the current queue. Application code should retain
stable media IDs rather than indices because insertions and removals shift
indices.

On Android, each player has its own queue and `DefaultPreloadManager`. The
current item and its immediate neighbors preload three seconds of samples.
Playback uses the same preloaded media source, so its prepared SampleQueue can
be handed to the player. Switching does not destroy the Player, Surface, or
Texture.

## View and state

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

`cacheProgress` is calculated by the local HLS proxy from cached media segments
and playlist `EXTINF` durations. `bufferedPosition` remains the native player's
current playable window.

## Lifecycle

The plugin does not add or evict business items automatically. Queue window
policy belongs entirely to the target application.

Release the playback session when its page or owner ends:

```dart
await controller.release();
```

This releases the Player, Surface, and Texture. Shut down the cache proxy when
the application no longer needs it:

```dart
await HlsCachePlayer.dispose();
```
