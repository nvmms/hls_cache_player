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

/// One application-managed entry in the native player's media queue.
class HlsQueueItem {
  const HlsQueueItem({required this.mediaId, required this.url})
      : assert(mediaId != ''),
        assert(url != '');

  /// Stable application identifier. Queue operations use this instead of an
  /// index because indices change after insertions and removals.
  final String mediaId;

  /// Loopback URL returned by [HlsCachePlayerPool.preload].
  final String url;

  Map<String, Object> toMessage() => <String, Object>{
        'mediaId': mediaId,
        'url': url,
      };
}

enum VideoPlaybackState { idle, buffering, ready, ended }

/// An immutable snapshot of one native player's complete observable state.
class VideoPlayerValue {
  const VideoPlayerValue({
    this.mediaId,
    this.mediaIndex = -1,
    this.isSwitching = false,
    this.playbackState = VideoPlaybackState.idle,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.cacheProgress = Duration.zero,
    this.playSpeed = 1.0,
    this.cacheSpeed = 0.0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.error,
  });

  final String? mediaId;
  final int mediaIndex;

  /// True after a queue selection until its first frame reaches the output.
  final bool isSwitching;

  final VideoPlaybackState playbackState;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;

  /// Media duration whose segments are present in the proxy cache.
  final Duration cacheProgress;

  /// Current playback rate, where `1.0` is normal speed.
  final double playSpeed;

  /// Rate at which playable media is being buffered, in media-seconds per
  /// wall-clock second. A value of `2.0` means buffering is advancing at 2x.
  final double cacheSpeed;
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

  /// Buffered media duration, capped at [duration] when it is known.
  ///
  /// For example, a 60-second video with 30 seconds buffered reports 30
  /// seconds here.
  /// Fraction of [duration] currently present in the proxy cache, clamped to
  /// 0...1.
  double get cacheProgressRatio => duration > Duration.zero
      ? (cacheProgress.inMilliseconds / duration.inMilliseconds)
          .clamp(0.0, 1.0)
          .toDouble()
      : 0.0;

  VideoPlayerValue copyWith({
    String? mediaId,
    int? mediaIndex,
    bool? isSwitching,
    bool clearMedia = false,
    VideoPlaybackState? playbackState,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    Duration? cacheProgress,
    double? playSpeed,
    double? cacheSpeed,
    int? videoWidth,
    int? videoHeight,
    String? error,
    bool clearError = false,
  }) =>
      VideoPlayerValue(
        mediaId: clearMedia ? null : mediaId ?? this.mediaId,
        mediaIndex: clearMedia ? -1 : mediaIndex ?? this.mediaIndex,
        isSwitching: isSwitching ?? this.isSwitching,
        playbackState: playbackState ?? this.playbackState,
        isPlaying: isPlaying ?? this.isPlaying,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        bufferedPosition: bufferedPosition ?? this.bufferedPosition,
        cacheProgress: cacheProgress ?? this.cacheProgress,
        playSpeed: playSpeed ?? this.playSpeed,
        cacheSpeed: cacheSpeed ?? this.cacheSpeed,
        videoWidth: videoWidth ?? this.videoWidth,
        videoHeight: videoHeight ?? this.videoHeight,
        error: clearError ? null : error ?? this.error,
      );
}
