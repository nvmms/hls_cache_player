import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'hls_cache_proxy.dart';
import 'video_models.dart';

/// The process-wide native player and its application-managed media queue.
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
  final Map<String, String> _urlsByMediaId = <String, String>{};
  late final StreamSubscription<Map<Object?, Object?>> _events;
  late final StreamController<VideoPlayerValue> _stateController;
  late final StreamController<Duration> _positionController;
  bool _disposed = false;
  DateTime? _lastBufferSampleAt;
  Duration _lastCacheProgress = Duration.zero;
  String? _lastMediaId;
  String? _requestedMediaId;

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

  /// Inserts one item. Existing [HlsQueueItem.mediaId] values are rejected.
  Future<void> insert(HlsQueueItem item, {int? index}) async {
    _assertLoopbackUrl(item.url);
    await _invoke('insert', {
      ...item.toMessage(),
      if (index != null) 'index': index,
    });
    _urlsByMediaId[item.mediaId] = item.url;
  }

  /// Inserts a batch while preserving its order.
  Future<void> insertAll(Iterable<HlsQueueItem> items, {int? index}) async {
    final list = items.toList(growable: false);
    for (final item in list) {
      _assertLoopbackUrl(item.url);
    }
    await _invoke('insertAll', {
      'items': list.map((item) => item.toMessage()).toList(growable: false),
      if (index != null) 'index': index,
    });
    for (final item in list) {
      _urlsByMediaId[item.mediaId] = item.url;
    }
  }

  Future<void> remove(String mediaId) async {
    await _invoke('remove', {'mediaId': mediaId});
    _urlsByMediaId.remove(mediaId);
    if (_requestedMediaId == mediaId) _requestedMediaId = null;
  }

  Future<void> removeAll(Iterable<String> mediaIds) async {
    final ids = mediaIds.toList(growable: false);
    await _invoke('removeAll', {'mediaIds': ids});
    for (final id in ids) {
      _urlsByMediaId.remove(id);
      if (_requestedMediaId == id) _requestedMediaId = null;
    }
  }

  /// Selects an existing queue entry and starts it without replacing the
  /// native player, surface, or texture.
  Future<void> playMedia(
    String mediaId, {
    Duration position = Duration.zero,
  }) async {
    // Selecting an already selected queue item is a resume, not another
    // seek-to-zero. Page views may report their initial page more than once.
    if (_requestedMediaId == mediaId) {
      await play();
      return;
    }
    _requestedMediaId = mediaId;
    _setValue(value.copyWith(mediaId: mediaId, isSwitching: true));
    try {
      await _invoke('playMedia', {
        'mediaId': mediaId,
        'positionMs': position.inMilliseconds,
      });
    } catch (_) {
      if (_requestedMediaId == mediaId) _requestedMediaId = null;
      if (!_disposed && value.mediaId == mediaId) {
        _setValue(value.copyWith(isSwitching: false));
      }
      rethrow;
    }
  }

  void _assertLoopbackUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'http' ||
        (uri.host != '127.0.0.1' &&
            uri.host != '::1' &&
            uri.host != 'localhost')) {
      throw ArgumentError.value(
        url,
        'url',
        'Must be a loopback URL returned by preload().',
      );
    }
  }

  Future<void> setPlaySpeed(double speed) async {
    if (!speed.isFinite || speed <= 0) {
      throw ArgumentError.value(speed, 'speed', 'Must be finite and positive.');
    }
    await _invoke('setPlaySpeed', {'speed': speed});
    if (!_disposed) _setValue(value.copyWith(playSpeed: speed));
  }

  /// Fetches state directly so events sent while player creation was completing are
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
    if (event['type'] == 'firstFrame') {
      final mediaId = event['mediaId']?.toString();
      if (mediaId != null && value.mediaId == mediaId) {
        _setValue(value.copyWith(isSwitching: false));
      }
      return;
    }
    if (event['type'] == 'error') {
      final domain = event['domain']?.toString();
      final code = event['code'];
      final details = domain == null ? '' : ' [$domain:$code]';
      final message = '${event['message'] ?? 'Native video playback failed.'}'
          '$details';
      debugPrint(
        'HlsPlayerController(playerId: $playerId, '
        'mediaId: ${event['mediaId']}) $message',
      );
      _setValue(value.copyWith(error: message));
      return;
    }
    if (event['type'] != 'state') return;
    final rawState = (event['playbackState'] as num?)?.toInt() ?? 1;
    final reportedBufferedPosition = Duration(
      milliseconds: (event['bufferedPositionMs'] as num?)?.toInt() ?? 0,
    );
    final duration = Duration(
      milliseconds: (event['durationMs'] as num?)?.toInt() ?? 0,
    );
    final position = Duration(
      milliseconds: (event['positionMs'] as num?)?.toInt() ?? 0,
    );
    final mediaId = event['mediaId']?.toString();
    if (mediaId != _lastMediaId) {
      _lastMediaId = mediaId;
      _lastBufferSampleAt = null;
      _lastCacheProgress = Duration.zero;
    }
    final playbackUrl = mediaId == null ? null : _urlsByMediaId[mediaId];
    final proxyCacheProgress = playbackUrl == null
        ? null
        : HlsCacheProxy.instance.cacheProgressFor(playbackUrl);
    final cacheProgress = proxyCacheProgress ??
        Duration(
          milliseconds: (event['cacheProgressMs'] as num?)?.toInt() ?? 0,
        );
    final now = DateTime.now();
    final elapsedUs = _lastBufferSampleAt == null
        ? 0
        : now.difference(_lastBufferSampleAt!).inMicroseconds;
    final cachedDeltaUs =
        cacheProgress.inMicroseconds - _lastCacheProgress.inMicroseconds;
    final cacheSpeed =
        elapsedUs > 0 && cachedDeltaUs > 0 ? cachedDeltaUs / elapsedUs : 0.0;
    _lastBufferSampleAt = now;
    _lastCacheProgress = cacheProgress;
    _setValue(value.copyWith(
      mediaId: mediaId,
      mediaIndex: (event['mediaIndex'] as num?)?.toInt() ?? -1,
      clearMedia: mediaId == null,
      playbackState: switch (rawState) {
        2 => VideoPlaybackState.buffering,
        3 => VideoPlaybackState.ready,
        4 => VideoPlaybackState.ended,
        _ => VideoPlaybackState.idle,
      },
      isPlaying: event['isPlaying'] == true,
      position: position,
      duration: duration,
      bufferedPosition: reportedBufferedPosition,
      cacheProgress: cacheProgress,
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
