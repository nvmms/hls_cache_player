import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'video_models.dart';

/// Controls one independent native player. Applications may pool and reuse
/// controllers across routes according to their own resource policy.
class HlsPlayerController extends ValueNotifier<VideoPlayerValue> {
  HlsPlayerController.internal(
    this.playerId,
    this.textureId,
  ) : super(const VideoPlayerValue()) {
    _stateController = StreamController<VideoPlayerValue>.broadcast(sync: true);
    _positionController = StreamController<Duration>.broadcast(sync: true);
    _events = NativeVideoBridge.eventStream
        .where((event) => event['playerId'] == playerId)
        .listen(_onEvent);
  }

  final int playerId;
  final int? textureId;
  final List<String> _playList = <String>[];
  final Map<String, String> _playbackUrls = {};
  final Map<String, VideoPlayerValue> _mediaValues = {};
  final Map<String, StreamController<VideoPlayerValue>> _mediaStateControllers =
      {};
  String? _currentMediaId;
  bool _standalone = false;
  late final StreamSubscription<Map<Object?, Object?>> _events;
  late final StreamController<VideoPlayerValue> _stateController;
  late final StreamController<Duration> _positionController;
  bool _disposed = false;
  DateTime? _lastBufferSampleAt;
  Duration _lastBufferedPosition = Duration.zero;

  /// Complete snapshots. Read [value] when an immediate value is needed.
  Stream<VideoPlayerValue> get states => _stateController.stream;

  /// Position-only updates for progress widgets that should rebuild locally.
  Stream<Duration> get positions => _positionController.stream;

  List<String> get playList => List.unmodifiable(_playList);
  String? get currentMediaId => _currentMediaId;

  /// Latest known state for [mediaId], or null when it has not been added.
  VideoPlayerValue? stateOf(String mediaId) => _mediaValues[mediaId];

  /// State updates for one media item. Every new listener first receives the
  /// latest snapshot, so it is safe to use directly with StreamBuilder.
  Stream<VideoPlayerValue> statesOf(String mediaId) {
    final updates = _mediaStateControllers
        .putIfAbsent(
          mediaId,
          () => StreamController<VideoPlayerValue>.broadcast(sync: true),
        )
        .stream;
    return Stream<VideoPlayerValue>.multi((events) {
      final current = stateOf(mediaId);
      if (current != null) events.add(current);
      final subscription = updates.listen(
        events.add,
        onError: events.addError,
        onDone: events.close,
      );
      events.onCancel = subscription.cancel;
    });
  }

  /// Adds a prepared playback URL to the native playlist.
  /// This method neither preloads nor prepares the native media item. Loading
  /// starts only after [moveTo] or [play].
  Future<void> addSource({
    required String mediaId,
    required String playbackUrl,
  }) async {
    _assertUsable();
    final previousUrl = _playbackUrls[mediaId];
    if (_playList.contains(mediaId) && previousUrl != null) {
      if (previousUrl == playbackUrl) {
        debugPrint(
          'HlsPlayerController(playerId: $playerId): mediaId "$mediaId" '
          'already has the same URL; ignoring addSource.',
        );
        return;
      }
      debugPrint(
        'HlsPlayerController(playerId: $playerId): mediaId "$mediaId" '
        'received a new URL; updating the existing playlist item.',
      );
      await _invoke('updateSource', {
        'mediaId': mediaId,
        'url': playbackUrl,
      });
      _playbackUrls[mediaId] = playbackUrl;
      return;
    }
    // Register the initial value before invoking native code. Native state
    // events can arrive before the method-channel future completes.
    if (!_mediaValues.containsKey(mediaId)) {
      _setMediaValue(mediaId, const VideoPlayerValue());
    }
    if (_standalone) {
      await _invoke('changeSource', {
        'mediaId': mediaId,
        'url': playbackUrl,
        'autoPlay': false,
      });
      _standalone = false;
    } else {
      await _invoke('addSource', {
        'mediaId': mediaId,
        'url': playbackUrl,
      });
    }
    _playList.add(mediaId);
    _playbackUrls[mediaId] = playbackUrl;
    _currentMediaId ??= mediaId;
  }

  /// Starts or resumes playback of [mediaId].
  ///
  /// Selecting the already-current item resumes it without seeking. Set
  /// [force] to true to restart it from the beginning. An item that has ended
  /// is always restarted, even when [force] is false. [looping] controls
  /// whether this item repeats when it reaches the end.
  Future<void> play({
    String? mediaId,
    bool force = false,
    bool looping = false,
  }) async {
    _assertUsable();
    final targetMediaId = mediaId ?? _currentMediaId;
    if (mediaId != null && !_playbackUrls.containsKey(mediaId)) {
      throw ArgumentError.value(mediaId, 'mediaId');
    }

    await setLooping(looping);

    if (targetMediaId != null && targetMediaId != _currentMediaId) {
      _deactivateCurrent(targetMediaId);
      _currentMediaId = targetMediaId;
    }
    await _invoke('play', {
      if (targetMediaId != null) 'mediaId': targetMediaId,
      'force': force,
    });
  }

  /// Selects and prepares [mediaId] without starting playback.
  Future<void> moveTo(String mediaId) async {
    final index = _playList.indexOf(mediaId);
    if (index < 0) {
      throw ArgumentError.value(
        mediaId,
        'mediaId',
        'Source has not been added.',
      );
    }
    _deactivateCurrent(mediaId);
    _setValue(
      (stateOf(mediaId) ?? const VideoPlayerValue()).copyWith(
        isPlaying: false,
        hasRenderedFirstFrame: false,
      ),
      mediaId: mediaId,
    );
    _currentMediaId = mediaId;
    await _invoke('moveTo', {'index': index});
  }

  /// Replaces playback with a standalone source while retaining the native
  /// player, Android texture, and iOS view.
  Future<void> changeSource({
    required String mediaId,
    required String playbackUrl,
    bool autoPlay = true,
  }) async {
    _deactivateCurrent(mediaId);
    _setValue(const VideoPlayerValue(), mediaId: mediaId);
    await _invoke('changeSource', {
      'mediaId': mediaId,
      'url': playbackUrl,
      'autoPlay': autoPlay,
    });
    _playList.clear();
    _playbackUrls
      ..clear()
      ..[mediaId] = playbackUrl;
    _currentMediaId = mediaId;
    _standalone = true;
  }

  Future<void> pause() => _invoke('pause');
  Future<void> seekTo(Duration position) =>
      _invoke('seekTo', {'positionMs': position.inMilliseconds});
  Future<void> setLooping(bool looping) =>
      _invoke('setLooping', {'looping': looping});
  Future<void> setPlaySpeed(double speed) async {
    if (!speed.isFinite || speed <= 0) {
      throw ArgumentError.value(speed, 'speed', 'Must be finite and positive.');
    }
    await _invoke('setPlaySpeed', {'speed': speed});
    if (!_disposed) _setValue(value.copyWith(playSpeed: speed));
  }

  /// Fetches state directly so events sent while acquire was completing are
  /// not lost through the event channel.
  Future<void> refresh() async {
    _assertUsable();
    final event = await NativeVideoBridge.methods
        .invokeMapMethod<Object?, Object?>('getState', {'playerId': playerId});
    if (event != null) _onEvent(event);
  }

  Future<void> _invoke(String method, [Map<String, Object>? arguments]) {
    _assertUsable();
    return NativeVideoBridge.methods.invokeMethod<void>(method, {
      'playerId': playerId,
      ...?arguments,
    });
  }

  void _onEvent(Map<Object?, Object?> event) {
    if (_disposed) return;
    if (event['type'] == 'error') {
      final domain = event['domain']?.toString();
      final code = event['code'];
      final details = domain == null ? '' : ' [$domain:$code]';
      final message = '${event['message'] ?? 'Native video playback failed.'}'
          '$details';
      debugPrint(
        'HlsPlayerController(playerId: $playerId, '
        'mediaId: $_currentMediaId) $message',
      );
      _setValue(value.copyWith(error: message), mediaId: _eventMediaId(event));
      return;
    }
    if (event['type'] != 'state') return;
    final mediaId = _eventMediaId(event);
    final rawState = (event['playbackState'] as num?)?.toInt() ?? 1;
    final bufferedPosition = Duration(
      milliseconds: (event['bufferedPositionMs'] as num?)?.toInt() ?? 0,
    );
    final now = DateTime.now();
    final elapsedUs = _lastBufferSampleAt == null
        ? 0
        : now.difference(_lastBufferSampleAt!).inMicroseconds;
    final bufferedDeltaUs =
        bufferedPosition.inMicroseconds - _lastBufferedPosition.inMicroseconds;
    final cacheSpeed = elapsedUs > 0 && bufferedDeltaUs > 0
        ? bufferedDeltaUs / elapsedUs
        : 0.0;
    _lastBufferSampleAt = now;
    _lastBufferedPosition = bufferedPosition;
    final previous =
        mediaId == null ? value : stateOf(mediaId) ?? const VideoPlayerValue();
    final next = previous.copyWith(
      playbackState: switch (rawState) {
        2 => VideoPlaybackState.buffering,
        3 => VideoPlaybackState.ready,
        4 => VideoPlaybackState.ended,
        _ => VideoPlaybackState.idle,
      },
      isPlaying: event['isPlaying'] == true,
      position: Duration(
        milliseconds: (event['positionMs'] as num?)?.toInt() ?? 0,
      ),
      duration: Duration(
        milliseconds: (event['durationMs'] as num?)?.toInt() ?? 0,
      ),
      bufferedPosition: bufferedPosition,
      playSpeed: (event['playSpeed'] as num?)?.toDouble() ?? previous.playSpeed,
      cacheSpeed: cacheSpeed,
      videoWidth: (event['videoWidth'] as num?)?.toInt() ?? 0,
      videoHeight: (event['videoHeight'] as num?)?.toInt() ?? 0,
      hasRenderedFirstFrame: event['hasRenderedFirstFrame'] == true,
      clearError: true,
    );
    if (mediaId != null && mediaId != _currentMediaId) {
      _setMediaValue(mediaId, next);
      return;
    }
    _setValue(next, mediaId: mediaId);
  }

  String? _eventMediaId(Map<Object?, Object?> event) {
    final mediaId = event['mediaId']?.toString();
    return mediaId == null || mediaId.isEmpty ? _currentMediaId : mediaId;
  }

  void _setValue(VideoPlayerValue next, {String? mediaId}) {
    final previousPosition = value.position;
    value = next;
    if (!_stateController.isClosed) _stateController.add(next);
    if (next.position != previousPosition && !_positionController.isClosed) {
      _positionController.add(next.position);
    }
    final targetMediaId = mediaId ?? _currentMediaId;
    if (targetMediaId != null) _setMediaValue(targetMediaId, next);
  }

  void _setMediaValue(String mediaId, VideoPlayerValue next) {
    _mediaValues[mediaId] = next;
    final controller = _mediaStateControllers[mediaId];
    if (controller != null && !controller.isClosed) controller.add(next);
  }

  void _deactivateCurrent(String nextMediaId) {
    final previousMediaId = _currentMediaId;
    if (previousMediaId == null || previousMediaId == nextMediaId) return;
    final previous = stateOf(previousMediaId) ?? const VideoPlayerValue();
    if (previous.isPlaying) {
      _setMediaValue(previousMediaId, previous.copyWith(isPlaying: false));
    }
  }

  void _assertUsable() {
    if (_disposed) throw StateError('The video controller was disposed.');
  }

  Future<void> release() async {
    if (_disposed) return;
    _disposed = true;
    await _events.cancel();
    await _stateController.close();
    await _positionController.close();
    await Future.wait(
        _mediaStateControllers.values.map((item) => item.close()));
    await NativeVideoBridge.methods.invokeMethod<void>('release', {
      'playerId': playerId,
    });
    super.dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _events.cancel();
    _stateController.close();
    _positionController.close();
    for (final controller in _mediaStateControllers.values) {
      controller.close();
    }
    NativeVideoBridge.methods.invokeMethod<void>('release', {
      'playerId': playerId,
    });
    super.dispose();
  }
}
