import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'hls_cache_player_method_channel.dart';

abstract class HlsCachePlayerPlatform extends PlatformInterface {
  /// Constructs a HlsCachePlayerPlatform.
  HlsCachePlayerPlatform() : super(token: _token);

  static final Object _token = Object();

  static HlsCachePlayerPlatform _instance = MethodChannelHlsCachePlayer();

  /// The default instance of [HlsCachePlayerPlatform] to use.
  ///
  /// Defaults to [MethodChannelHlsCachePlayer].
  static HlsCachePlayerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [HlsCachePlayerPlatform] when
  /// they register themselves.
  static set instance(HlsCachePlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
