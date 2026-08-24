import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'hls_cache_player_platform_interface.dart';

/// An implementation of [HlsCachePlayerPlatform] that uses method channels.
class MethodChannelHlsCachePlayer extends HlsCachePlayerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('hls_cache_player');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
