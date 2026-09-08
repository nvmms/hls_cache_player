import 'native_bridge.dart';
import 'hls_cache_proxy.dart';
import 'video_controller.dart';

/// Entry point for the single process-wide native player.
class HlsCachePlayer {
  HlsCachePlayer._();

  static HlsPlayerController? _controller;
  static Future<HlsPlayerController>? _creating;

  static Future<HlsPlayerController> create({
    int memoryCacheBytes = 48 * 1024 * 1024,
    int diskCacheBytes = 768 * 1024 * 1024,
  }) async {
    final existing = _controller;
    if (existing != null) return existing;
    final pending = _creating;
    if (pending != null) return pending;
    final creation = _create(
      memoryCacheBytes: memoryCacheBytes,
      diskCacheBytes: diskCacheBytes,
    );
    _creating = creation;
    try {
      return await creation;
    } finally {
      if (identical(_creating, creation)) _creating = null;
    }
  }

  static Future<HlsPlayerController> _create({
    required int memoryCacheBytes,
    required int diskCacheBytes,
  }) async {
    await NativeVideoBridge.methods.invokeMethod<void>('configure', {
      'memoryCacheBytes': memoryCacheBytes,
      'diskCacheBytes': diskCacheBytes,
    });
    await HlsCacheProxy.instance.configure(
      memoryCacheBytes: memoryCacheBytes,
      diskCacheBytes: diskCacheBytes,
    );
    final created = await NativeVideoBridge.methods
        .invokeMapMethod<Object?, Object?>('createPlayer', const {});
    final id = (created?['playerId'] as num?)?.toInt();
    if (id == null) throw StateError('Native player did not return an id.');
    final controller = HlsPlayerController.internal(
      id,
      (created?['textureId'] as num?)?.toInt(),
    );
    _controller = controller;
    return controller;
  }

  static Future<void> dispose() async {
    await _creating;
    final controller = _controller;
    _controller = null;
    if (controller != null) await controller.release();
    await NativeVideoBridge.methods.invokeMethod<void>('dispose');
    await HlsCacheProxy.instance.dispose();
  }
}
