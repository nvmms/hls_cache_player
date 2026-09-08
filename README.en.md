# hls_cache_player

A single-instance HLS player for Android and iOS with memory/disk caching,
playlist navigation, and in-place source replacement.

The native player, Android `Texture`, and iOS player view are created once.
Use `addSource` to append media, `moveTo(index)` or `play(mediaId)` to select a
playlist item, and `changeSource` for standalone playback while retaining the
same player and rendering object.

```dart
final player = await HlsCachePlayer.create();
await player.addSource(const HlsVideoSource(
  cacheKey: 'episode-1', // also used as mediaId
  url: 'https://example.com/1.m3u8',
));
await player.addSource(const HlsVideoSource(
  cacheKey: 'episode-2',
  url: 'https://example.com/2.m3u8',
));

await player.moveTo(1);
await player.play();
// Or: await player.play('episode-1');

await player.changeSource(const HlsVideoSource(
  cacheKey: 'live',
  url: 'https://example.com/live.m3u8',
));
```

Render with `HlsPlayerView(controller: player)`. Call
`await HlsCachePlayer.dispose()` when the application no longer needs it.

`cacheKey` is the unique `mediaId` inside a playlist. `changeSource` leaves
playlist mode, so `player.playList` becomes empty; the next `addSource` starts a
new playlist.
