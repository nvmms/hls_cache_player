import 'package:flutter_test/flutter_test.dart';
import 'package:vertical_sliding_video/vertical_sliding_video.dart';
import 'package:vertical_sliding_video/vertical_sliding_video_platform_interface.dart';
import 'package:vertical_sliding_video/vertical_sliding_video_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockVerticalSlidingVideoPlatform
    with MockPlatformInterfaceMixin
    implements VerticalSlidingVideoPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final VerticalSlidingVideoPlatform initialPlatform = VerticalSlidingVideoPlatform.instance;

  test('$MethodChannelVerticalSlidingVideo is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelVerticalSlidingVideo>());
  });

  test('getPlatformVersion', () async {
    VerticalSlidingVideo verticalSlidingVideoPlugin = VerticalSlidingVideo();
    MockVerticalSlidingVideoPlatform fakePlatform = MockVerticalSlidingVideoPlatform();
    VerticalSlidingVideoPlatform.instance = fakePlatform;

    expect(await verticalSlidingVideoPlugin.getPlatformVersion(), '42');
  });
}
