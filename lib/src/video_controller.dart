import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'video_models.dart';

/// A lease on one native player. The same controller can be rendered by
/// different routes; do not dispose it during the route hand-off.
class HlsPlayerController extends ValueNotifier<VideoPlayerValue> {
  HlsPlayerController.internal(
    this.playerId,
    this.playbackUrl,
    this.textureId,
  ) : super(const VideoPlayerValue()) {
    _stateController = StreamController<VideoPlayerValue>.broadcast(sync: true);
    _positionController = StreamController<Duration>.broadcast(sync: true);
    _events = NativeVideoBridge.eventStream
        .where((event) => event['playerId'] == playerId)
        .listen(_onEvent);
  }

  final int playerId;
  final String playbackUrl;
  final int? textureId;
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

  Future<void> play() => _invoke('play');
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
        'url: $playbackUrl) $message',
      );
      _setValue(value.copyWith(error: message));
      return;
    }
    if (event['type'] != 'state') return;
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
    _setValue(value.copyWith(
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
      playSpeed: (event['playSpeed'] as num?)?.toDouble() ?? value.playSpeed,
      cacheSpeed: cacheSpeed,
      videoWidth: (event['videoWidth'] as num?)?.toInt() ?? 0,
      videoHeight: (event['videoHeight'] as num?)?.toInt() ?? 0,
      clearError: true,
    ));
  }

  void _setValue(VideoPlayerValue next) {
    final previousPosition = value.position;
    value = next;
    if (!_stateController.isClosed) _stateController.add(next);
    if (next.position != previousPosition && !_positionController.isClosed) {
      _positionController.add(next.position);
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
    NativeVideoBridge.methods.invokeMethod<void>('release', {
      'playerId': playerId,
    });
    super.dispose();
  }
}
