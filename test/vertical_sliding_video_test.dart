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
  });
}
