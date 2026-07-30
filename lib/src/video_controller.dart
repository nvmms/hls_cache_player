import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'video_models.dart';

/// A lease on one native player. The same controller can be rendered by
/// different routes; do not dispose it during the route hand-off.
class VerticalVideoController extends ValueNotifier<VideoPlayerValue> {
  VerticalVideoController.internal(this.playerId, this.source, this.textureId)
      : super(const VideoPlayerValue()) {
    _events = NativeVideoBridge.eventStream
        .where((event) => event['playerId'] == playerId)
        .listen(_onEvent);
  }

  final int playerId;
  final HlsVideoSource source;
  final int? textureId;
  late final StreamSubscription<Map<Object?, Object?>> _events;
  bool _disposed = false;

  Future<void> play() => _invoke('play');
  Future<void> pause() => _invoke('pause');
  Future<void> seekTo(Duration position) =>
      _invoke('seekTo', {'positionMs': position.inMilliseconds});
  Future<void> setLooping(bool looping) =>
      _invoke('setLooping', {'looping': looping});

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
      value = value.copyWith(error: event['message']?.toString());
      return;
    }
    if (event['type'] != 'state') return;
    final rawState = (event['playbackState'] as num?)?.toInt() ?? 1;
    value = value.copyWith(
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
    );
  }

  void _assertUsable() {
    if (_disposed) throw StateError('The video controller was disposed.');
  }

  Future<void> release() async {
    if (_disposed) return;
    _disposed = true;
    await _events.cancel();
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
    NativeVideoBridge.methods.invokeMethod<void>('release', {
      'playerId': playerId,
    });
    super.dispose();
  }
}
