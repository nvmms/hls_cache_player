/// A user-addressable HLS resource.
///
/// [cacheKey] is the stable namespace used by the native memory and disk cache.
/// Change it when the bytes behind [url] change.
class HlsVideoSource {
  const HlsVideoSource({
    required this.cacheKey,
    required this.url,
    this.headers = const <String, String>{},
  })  : assert(cacheKey != ''),
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

/// An immutable snapshot of one native player's complete observable state.
class VideoPlayerValue {
  const VideoPlayerValue({
    this.playbackState = VideoPlaybackState.idle,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.error,
  });

  final VideoPlaybackState playbackState;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final int videoWidth;
  final int videoHeight;
  final String? error;

  bool get isInitialized =>
      playbackState == VideoPlaybackState.ready ||
      playbackState == VideoPlaybackState.ended;
  bool get isBuffering => playbackState == VideoPlaybackState.buffering;
  bool get isEnded => playbackState == VideoPlaybackState.ended;
  double get aspectRatio =>
      videoWidth > 0 && videoHeight > 0 ? videoWidth / videoHeight : 0;

  VideoPlayerValue copyWith({
    VideoPlaybackState? playbackState,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    int? videoWidth,
    int? videoHeight,
    String? error,
    bool clearError = false,
  }) =>
      VideoPlayerValue(
        playbackState: playbackState ?? this.playbackState,
        isPlaying: isPlaying ?? this.isPlaying,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        bufferedPosition: bufferedPosition ?? this.bufferedPosition,
        videoWidth: videoWidth ?? this.videoWidth,
        videoHeight: videoHeight ?? this.videoHeight,
        error: clearError ? null : error ?? this.error,
      );
}
