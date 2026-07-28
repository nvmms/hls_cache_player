import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'vertical_sliding_video_method_channel.dart';

abstract class VerticalSlidingVideoPlatform extends PlatformInterface {
  /// Constructs a VerticalSlidingVideoPlatform.
  VerticalSlidingVideoPlatform() : super(token: _token);

  static final Object _token = Object();

  static VerticalSlidingVideoPlatform _instance = MethodChannelVerticalSlidingVideo();

  /// The default instance of [VerticalSlidingVideoPlatform] to use.
  ///
  /// Defaults to [MethodChannelVerticalSlidingVideo].
  static VerticalSlidingVideoPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [VerticalSlidingVideoPlatform] when
  /// they register themselves.
  static set instance(VerticalSlidingVideoPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
