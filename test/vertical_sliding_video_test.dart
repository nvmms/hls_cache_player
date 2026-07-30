import 'package:flutter_test/flutter_test.dart';
import 'package:vertical_sliding_video/vertical_sliding_video.dart';

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
