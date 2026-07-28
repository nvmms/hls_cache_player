import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vertical_sliding_video_platform_interface.dart';

/// An implementation of [VerticalSlidingVideoPlatform] that uses method channels.
class MethodChannelVerticalSlidingVideo extends VerticalSlidingVideoPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('vertical_sliding_video');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
