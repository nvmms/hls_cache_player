import 'native_bridge.dart';
import 'video_controller.dart';

/// Process-wide cache service and factory for independent native players.
class HlsCachePlayer {
  HlsCachePlayer._();

  static bool _configured = false;
  static Future<void>? _configuring;

  static Future<HlsPlayerController> create({
    int memoryCacheBytes = 48 * 1024 * 1024,
    int diskCacheBytes = 768 * 1024 * 1024,
  }) async {
    await configure(
      memoryCacheBytes: memoryCacheBytes,
      diskCacheBytes: diskCacheBytes,
    );
    return _createController();
  }

  static Future<void> configure({
    int memoryCacheBytes = 48 * 1024 * 1024,
    int diskCacheBytes = 768 * 1024 * 1024,
  }) async {
    if (_configured) return;
    final pending = _configuring;
    if (pending != null) return pending;
    final configuring = _configure(
      memoryCacheBytes: memoryCacheBytes,
      diskCacheBytes: diskCacheBytes,
    );
    _configuring = configuring;
    try {
      await configuring;
      _configured = true;
    } finally {
      if (identical(_configuring, configuring)) _configuring = null;
    }
  }

  static Future<void> _configure({
    required int memoryCacheBytes,
    required int diskCacheBytes,
  }) async {
    await NativeVideoBridge.methods.invokeMethod<void>('configure', {
      'memoryCacheBytes': memoryCacheBytes,
      'diskCacheBytes': diskCacheBytes,
    });
  }

  static Future<HlsPlayerController> _createController() async {
    final created = await NativeVideoBridge.methods
        .invokeMapMethod<Object?, Object?>('createPlayer', const {});
    final id = (created?['playerId'] as num?)?.toInt();
    if (id == null) throw StateError('Native player did not return an id.');
    return HlsPlayerController.internal(
      id,
      (created?['textureId'] as num?)?.toInt(),
    );
  }

  static Future<void> dispose() async {
    await _configuring;
    await NativeVideoBridge.methods.invokeMethod<void>('dispose');
    _configured = false;
  }
}
