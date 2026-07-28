import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vertical_sliding_video/vertical_sliding_video.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('vertical_sliding_video/methods');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'acquire') return 7;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('pool forwards the user cache key to preload', () async {
    const source = HlsVideoSource(
      cacheKey: 'custom-key',
      url: 'https://example.com/a.m3u8',
    );
    await VerticalVideoPool.configure();
    await VerticalVideoPool.preload(source);

    expect(calls.last.method, 'preload');
    expect((calls.last.arguments as Map)['cacheKey'], 'custom-key');
  });
}
