import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'video_models.dart';

/// A lease on one native player. The same controller can be rendered by
/// different routes; do not dispose it during the route hand-off.
class VerticalVideoController extends ValueNotifier<VideoPlayerValue> {
  VerticalVideoController.internal(this.playerId, this.source, this.textureId)
      : super(const VideoPlayerValue()) {
    _stateController = StreamController<VideoPlayerValue>.broadcast(sync: true);
    _positionController = StreamController<Duration>.broadcast(sync: true);
    _events = NativeVideoBridge.eventStream
        .where((event) => event['playerId'] == playerId)
        .listen(_onEvent);
  }

  final int playerId;
  final HlsVideoSource source;
  final int? textureId;
  late final StreamSubscription<Map<Object?, Object?>> _events;
  late final StreamController<VideoPlayerValue> _stateController;
  late final StreamController<Duration> _positionController;
  bool _disposed = false;

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
        'VerticalVideoController(playerId: $playerId, '
        'url: ${source.url}) $message',
      );
      _setValue(value.copyWith(error: message));
      return;
    }
    if (event['type'] != 'state') return;
    final rawState = (event['playbackState'] as num?)?.toInt() ?? 1;
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
      bufferedPosition: Duration(
        milliseconds: (event['bufferedPositionMs'] as num?)?.toInt() ?? 0,
      ),
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
