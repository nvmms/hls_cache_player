import 'package:flutter_test/flutter_test.dart';
import 'package:hls_cache_player/hls_cache_player.dart';

void main() {
  test('HlsVideoSource exposes a user supplied cache key', () {
    const source = HlsVideoSource(
      cacheKey: 'post-42-v3',
      url: 'https://example.com/video.m3u8',
      headers: {'Authorization': 'Bearer test'},
    );

    expect(source.toMessage(), {
      'cacheKey': 'post-42-v3',
      'url': 'https://example.com/video.m3u8',
      'headers': {'Authorization': 'Bearer test'},
    });
  });

  test('VideoPlayerValue has safe initial values', () {
    const value = VideoPlayerValue();
    expect(value.playbackState, VideoPlaybackState.idle);
    expect(value.position, Duration.zero);
    expect(value.isPlaying, isFalse);
    expect(value.isInitialized, isFalse);
    expect(value.isBuffering, isFalse);
    expect(value.aspectRatio, 0);
    expect(value.playSpeed, 1.0);
    expect(value.cacheProgress, Duration.zero);
    expect(value.cacheProgressRatio, 0.0);
    expect(value.cacheSpeed, 0.0);
  });

  test('VideoPlayerValue exposes cache progress and speed', () {
    const value = VideoPlayerValue(
      duration: Duration(seconds: 10),
      bufferedPosition: Duration(seconds: 4),
      cacheProgress: Duration(seconds: 4),
      playSpeed: 1.5,
      cacheSpeed: 3.25,
    );

    expect(value.cacheProgress, const Duration(seconds: 4));
    expect(value.cacheProgressRatio, 0.4);
    expect(value.playSpeed, 1.5);
    expect(value.cacheSpeed, 3.25);
  });

  test('cache progress ratio cannot exceed the known duration', () {
    const value = VideoPlayerValue(
      duration: Duration(seconds: 60),
      bufferedPosition: Duration(seconds: 75),
      cacheProgress: Duration(seconds: 75),
    );

    expect(value.cacheProgress, const Duration(seconds: 75));
    expect(value.cacheProgressRatio, 1.0);
  });

  test('copyWith can preserve a cache high-water mark across looping', () {
    const firstPass = VideoPlayerValue(
      duration: Duration(seconds: 60),
      bufferedPosition: Duration(seconds: 60),
      cacheProgress: Duration(seconds: 60),
    );
    final looped = firstPass.copyWith(position: Duration.zero);

    expect(looped.cacheProgress, const Duration(seconds: 60));
    expect(looped.cacheProgressRatio, 1.0);
  });

  test('VideoPlayerValue exposes derived playback state', () {
    const value = VideoPlayerValue(
      playbackState: VideoPlaybackState.ready,
      videoWidth: 1920,
      videoHeight: 1080,
    );

    expect(value.isInitialized, isTrue);
    expect(value.aspectRatio, closeTo(16 / 9, 0.0001));
  });

  test('VideoPlayerValue tracks the stable queue identity', () {
    const value = VideoPlayerValue(
      mediaId: 'video-42',
      mediaIndex: 7,
      isSwitching: true,
    );
    final shifted = value.copyWith(mediaIndex: 5);

    expect(shifted.mediaId, 'video-42');
    expect(shifted.mediaIndex, 5);
    expect(shifted.isSwitching, isTrue);
    expect(shifted.copyWith(clearMedia: true).mediaId, isNull);
    expect(shifted.copyWith(clearMedia: true).mediaIndex, -1);
  });

  test('HlsQueueItem serializes its stable identity and local URL', () {
    const item = HlsQueueItem(
      mediaId: 'video-42',
      url: 'http://127.0.0.1:1234/video.m3u8',
    );

    expect(item.toMessage(), {
      'mediaId': 'video-42',
      'url': 'http://127.0.0.1:1234/video.m3u8',
    });
  });

  test('VideoPlayerValue retains and explicitly clears errors', () {
    const failed = VideoPlayerValue(error: 'network');

    expect(
        failed.copyWith(position: const Duration(seconds: 1)).error, 'network');
    expect(failed.copyWith(clearError: true).error, isNull);
  });
}
