import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'hls_cache_proxy.dart';
import 'video_controller.dart';
import 'video_models.dart';

/// Process-wide entry point for preloading and one native playback session.
class HlsCachePlayerPool {
  HlsCachePlayerPool._();

  static bool _configured = false;

  static Future<void> configure({
    int memoryCacheBytes = 48 * 1024 * 1024,
    int diskCacheBytes = 768 * 1024 * 1024,
  }) async {
    await NativeVideoBridge.methods.invokeMethod<void>('configure', {
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

  /// Creates the process-wide player and its fixed video output.
  ///
  /// The target application owns queue policy through [HlsPlayerController].
  static Future<HlsPlayerController> createController({
    bool looping = true,
  }) async {
    await _ensureConfigured();
    final acquired = await NativeVideoBridge.methods.invokeMethod<Object?>(
      'createPlayer',
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
