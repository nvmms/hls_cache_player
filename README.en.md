# hls_cache_player

A single-instance HLS player for Android and iOS with memory/disk caching,
playlist navigation, and in-place source replacement.

The native player, Android `Texture`, and iOS player view are created once.
Use `addSource` to append media, `moveTo(mediaId)` or `play(mediaId)` to select a
playlist item, and `changeSource` for standalone playback while retaining the
same player and rendering object.

```dart
final player = await HlsCachePlayer.create();
final episode1Url = await HlsCacheProxy.preload(const HlsVideoSource(
  cacheKey: 'episode-1', // also used as mediaId
  url: 'https://example.com/1.m3u8',
));
final episode2Url = await HlsCacheProxy.preload(const HlsVideoSource(
  cacheKey: 'episode-2',
  url: 'https://example.com/2.m3u8',
));
await player.addSource(mediaId: 'episode-1', playbackUrl: episode1Url);
await player.addSource(mediaId: 'episode-2', playbackUrl: episode2Url);

await player.moveTo('episode-2');
await player.play();
// Or: await player.play('episode-1');
// Playback pauses at the end; the next item is never started automatically.

final liveUrl = await HlsCacheProxy.preload(const HlsVideoSource(
  cacheKey: 'live',
  url: 'https://example.com/live.m3u8',
));
await player.changeSource(mediaId: 'live', playbackUrl: liveUrl);
```

Render with `HlsPlayerView(controller: player)`. Call
`await HlsCachePlayer.dispose()` when the application no longer needs it.
The player and proxy have independent lifecycles. Only call
`await HlsCacheProxy.dispose()` when no returned local URL is still in use;
disposing the proxy invalidates every previously returned loopback URL.

`cacheKey` is the unique `mediaId` inside a playlist. `changeSource` leaves
playlist mode, so `player.playList` becomes empty; the next `addSource` starts a
new playlist.
