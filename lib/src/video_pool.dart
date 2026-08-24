import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'hls_cache_proxy.dart';
import 'video_controller.dart';
import 'video_models.dart';

/// Process-wide entry point for preloading and leasing native players.
class HlsCachePlayerPool {
  HlsCachePlayerPool._();

  static bool _configured = false;

  static Future<void> configure({
    /// Number of idle native players retained for fast reuse.
    ///
    /// Active leases may temporarily exceed this value. Overflow players are
    /// released instead of being retained when their final lease ends.
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
    await HlsCacheProxy.instance.configure(
      memoryCacheBytes: memoryCacheBytes,
      diskCacheBytes: diskCacheBytes,
    );
    _configured = true;
  }

  /// Preloads the HLS playlist, key/init resource, and first media segment.
  /// Returns a process-local HTTP URL that can be passed to any HLS player.
  static Future<String> preload(HlsVideoSource source) async {
    await _ensureConfigured();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final localUrl = await NativeVideoBridge.methods.invokeMethod<String>(
        'preload',
        source.toMessage(),
      );
      if (localUrl == null) {
        throw StateError('Native iOS proxy did not return a local URL.');
      }
      return localUrl;
    }
    return HlsCacheProxy.instance.preload(source);
  }

  static Future<List<String>> preloadAll(
      Iterable<HlsVideoSource> sources) async {
    await _ensureConfigured();
    return Future.wait(sources.map(preload));
  }

  /// Leases a native player for a URL returned by [preload].
  static Future<HlsPlayerController> acquire(
    String localProxyUrl, {
    bool autoPlay = false,
    bool looping = true,
  }) async {
    await _ensureConfigured();
    final uri = Uri.tryParse(localProxyUrl);
    if (uri == null ||
        uri.scheme != 'http' ||
        (uri.host != '127.0.0.1' &&
            uri.host != '::1' &&
            uri.host != 'localhost')) {
      throw ArgumentError.value(
        localProxyUrl,
        'localProxyUrl',
        'Must be a loopback URL returned by preload().',
      );
    }
    final acquired = await NativeVideoBridge.methods.invokeMethod<Object?>(
      'acquire',
      {
        'url': localProxyUrl,
        'autoPlay': autoPlay,
      },
    );
    final int? id;
    final int? textureId;
    if (acquired is Map) {
      id = (acquired['playerId'] as num?)?.toInt();
      textureId = (acquired['textureId'] as num?)?.toInt();
    } else {
      id = (acquired as num?)?.toInt();
      textureId = null;
    }
    if (id == null) throw StateError('Native player did not return an id.');
    final controller = HlsPlayerController.internal(
      id,
      localProxyUrl,
      textureId,
    );
    await controller.refresh();
    if (looping) await controller.setLooping(true);
    return controller;
  }

  static Future<void> _ensureConfigured() async {
    if (!_configured) await configure();
  }

  static Future<void> dispose() async {
    await NativeVideoBridge.methods.invokeMethod<void>('dispose');
    await HlsCacheProxy.instance.dispose();
    _configured = false;
  }
}
