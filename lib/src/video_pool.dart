import 'native_bridge.dart';
import 'video_controller.dart';
import 'video_models.dart';

/// Process-wide entry point for preloading and leasing native players.
class VerticalVideoPool {
  VerticalVideoPool._();

  static bool _configured = false;

  static Future<void> configure({
    int maxPlayers = 3,
    int memoryCacheBytes = 48 * 1024 * 1024,
    int diskCacheBytes = 768 * 1024 * 1024,
  }) async {
    if (maxPlayers < 1) throw ArgumentError.value(maxPlayers, 'maxPlayers');
    await NativeVideoBridge.methods.invokeMethod<void>('configure', {
      'maxPlayers': maxPlayers,
      'memoryCacheBytes': memoryCacheBytes,
      'diskCacheBytes': diskCacheBytes,
    });
    _configured = true;
  }

  /// Preloads the HLS playlist, key/init resource, and first media segment.
  static Future<void> preload(HlsVideoSource source) async {
    await _ensureConfigured();
    await NativeVideoBridge.methods.invokeMethod<void>(
      'preload',
      source.toMessage(),
    );
  }

  static Future<void> preloadAll(Iterable<HlsVideoSource> sources) async {
    await _ensureConfigured();
    await Future.wait(sources.map(preload));
  }

  /// Leases a native player. Pass the returned controller between routes to
  /// continue playback without preparing a second player.
  static Future<VerticalVideoController> acquire(
    HlsVideoSource source, {
    bool autoPlay = false,
    bool looping = true,
  }) async {
    await _ensureConfigured();
    final id = await NativeVideoBridge.methods.invokeMethod<int>('acquire', {
      ...source.toMessage(),
      'autoPlay': autoPlay,
    });
    if (id == null) throw StateError('Native player did not return an id.');
    final controller = VerticalVideoController.internal(id, source);
    if (looping) await controller.setLooping(true);
    return controller;
  }

  static Future<void> _ensureConfigured() async {
    if (!_configured) await configure();
  }

  static Future<void> dispose() async {
    await NativeVideoBridge.methods.invokeMethod<void>('dispose');
    _configured = false;
  }
}
