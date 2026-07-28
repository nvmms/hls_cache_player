
import 'vertical_sliding_video_platform_interface.dart';

class VerticalSlidingVideo {
  Future<String?> getPlatformVersion() {
    return VerticalSlidingVideoPlatform.instance.getPlatformVersion();
  }
}
