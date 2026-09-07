## Unreleased

- Add ordinary playback with setUrl, playUrl, and cached setSource alongside optional queues.

## Unreleased

- Replace HlsCachePlayerPool with HlsCachePlayer. Each createController call creates an independent native player; applications own pooling and reuse.
- Route queues by playerId and isolate Android preload managers per player.

## 0.0.1

* TODO: Describe initial release.
