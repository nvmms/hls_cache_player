import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'hls_cache_proxy.dart';
import 'video_models.dart';

/// Controls the process-wide native player. The same controller and rendering
/// object can be reused by different routes.
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
  final List<HlsVideoSource> _playList = <HlsVideoSource>[];
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

  List<HlsVideoSource> get playList => List.unmodifiable(_playList);
  String? get currentMediaId => _currentMediaId;

  Future<void> addSource(HlsVideoSource source) async {
    _assertUsable();
    if (_playList.any((item) => item.cacheKey == source.cacheKey)) {
      throw ArgumentError.value(source.cacheKey, 'source.cacheKey',
          'mediaId must be unique in the playlist.');
    }
    final url = await _preload(source);
    if (_standalone) {
      await _invoke('changeSource', {
        'mediaId': source.cacheKey,
        'url': url,
        'autoPlay': false,
      });
      _standalone = false;
    } else {
      await _invoke('addSource', {'mediaId': source.cacheKey, 'url': url});
    }
    _playList.add(source);
    _currentMediaId ??= source.cacheKey;
  }

  Future<void> play([String? mediaId]) async {
    if (mediaId != null) {
      final index = _playList.indexWhere((item) => item.cacheKey == mediaId);
      if (index < 0) throw ArgumentError.value(mediaId, 'mediaId');
      await moveTo(index);
    }
    await _invoke('play');
  }

  Future<void> moveTo(int index) async {
    if (index < 0 || index >= _playList.length) {
      throw RangeError.index(index, _playList, 'index');
    }
    await _invoke('moveTo', {'index': index});
    _currentMediaId = _playList[index].cacheKey;
  }

  /// Replaces playback with a standalone source while retaining the native
  /// player, Android texture, and iOS view.
  Future<void> changeSource(HlsVideoSource source,
      {bool autoPlay = true}) async {
    final url = await _preload(source);
    await _invoke('changeSource', {
      'mediaId': source.cacheKey,
      'url': url,
      'autoPlay': autoPlay,
    });
    _playList.clear();
    _currentMediaId = source.cacheKey;
    _standalone = true;
  }

  Future<String> _preload(HlsVideoSource source) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final url = await NativeVideoBridge.methods
          .invokeMethod<String>('preload', source.toMessage());
      if (url == null) throw StateError('Native iOS proxy returned no URL.');
      return url;
    }
    return HlsCacheProxy.instance.preload(source);
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
      _setValue(value.copyWith(error: message));
      return;
    }
    if (event['type'] != 'state') return;
    _currentMediaId = event['mediaId']?.toString() ?? _currentMediaId;
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
