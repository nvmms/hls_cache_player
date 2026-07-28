import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vertical_sliding_video/vertical_sliding_video_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelVerticalSlidingVideo platform = MethodChannelVerticalSlidingVideo();
  const MethodChannel channel = MethodChannel('vertical_sliding_video');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return '42';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
