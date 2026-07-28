/// A user-addressable HLS resource.
///
/// [cacheKey] is the stable namespace used by the native memory and disk cache.
/// Change it when the bytes behind [url] change.
class HlsVideoSource {
  const HlsVideoSource({
    required this.cacheKey,
    required this.url,
    this.headers = const <String, String>{},
  }) : assert(cacheKey != ''),
       assert(url != '');

  final String cacheKey;
  final String url;
  final Map<String, String> headers;

  Map<String, Object> toMessage() => <String, Object>{
    'cacheKey': cacheKey,
    'url': url,
    'headers': headers,
  };
}

enum VideoPlaybackState { idle, buffering, ready, ended }

class VideoPlayerValue {
  const VideoPlayerValue({
    this.playbackState = VideoPlaybackState.idle,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.error,
  });

  final VideoPlaybackState playbackState;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final String? error;

  VideoPlayerValue copyWith({
    VideoPlaybackState? playbackState,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    String? error,
  }) => VideoPlayerValue(
    playbackState: playbackState ?? this.playbackState,
    isPlaying: isPlaying ?? this.isPlaying,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    bufferedPosition: bufferedPosition ?? this.bufferedPosition,
    error: error,
  );
}
