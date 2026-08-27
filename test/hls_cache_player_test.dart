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
      playSpeed: 1.5,
      cacheSpeed: 3.25,
    );

    expect(value.cacheProgress, const Duration(seconds: 4));
    expect(value.cacheProgressRatio, 0.4);
    expect(value.playSpeed, 1.5);
    expect(value.cacheSpeed, 3.25);
  });

  test('cache progress cannot exceed the known duration', () {
    const value = VideoPlayerValue(
      duration: Duration(seconds: 60),
      bufferedPosition: Duration(seconds: 75),
    );

    expect(value.cacheProgress, const Duration(seconds: 60));
    expect(value.cacheProgressRatio, 1.0);
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

  test('VideoPlayerValue retains and explicitly clears errors', () {
    const failed = VideoPlayerValue(error: 'network');

    expect(
        failed.copyWith(position: const Duration(seconds: 1)).error, 'network');
    expect(failed.copyWith(clearError: true).error, isNull);
  });
}
