import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vertical_sliding_video/vertical_sliding_video.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('vertical_sliding_video/methods');
  final calls = <MethodCall>[];
  late Directory cacheDirectory;
  late HttpServer upstream;

  setUp(() async {
    HttpOverrides.global = null;
    cacheDirectory = await Directory.systemTemp.createTemp('vsv_pool_test_');
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      if (request.uri.path.endsWith('.m3u8')) {
        request.response.write('''#EXTM3U
#EXTINF:1,
one.ts
#EXTINF:1,
two.ts
#EXT-X-ENDLIST
''');
      } else {
        request.response.add([1, 2, 3]);
      }
      await request.response.close();
    });
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'acquire') return 7;
      if (call.method == 'cacheDirectory') return cacheDirectory.path;
      return null;
    });
  });

  tearDown(() async {
    await VerticalVideoPool.dispose();
    await upstream.close(force: true);
    await cacheDirectory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('pool forwards only the local proxy URL to acquire', () async {
    await VerticalVideoPool.configure();
    final localUrl = await VerticalVideoPool.preload(
      HlsVideoSource(
        cacheKey: 'method-channel',
        url: 'http://${upstream.address.address}:${upstream.port}/video.m3u8',
      ),
    );
    final controller = await VerticalVideoPool.acquire(localUrl);

    final acquire = calls.firstWhere((call) => call.method == 'acquire');
    expect(acquire.arguments, {
      'url': localUrl,
      'autoPlay': false,
    });
    await controller.release();
  });

  test('pool accepts an Android texture acquire response', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'acquire') {
        return <String, Object>{'playerId': 7, 'textureId': 11};
      }
      if (call.method == 'cacheDirectory') return cacheDirectory.path;
      return null;
    });

    final localUrl = await VerticalVideoPool.preload(
      HlsVideoSource(
        cacheKey: 'texture-key',
        url: 'http://${upstream.address.address}:${upstream.port}/video.m3u8',
      ),
    );
    final controller = await VerticalVideoPool.acquire(localUrl);

    expect(controller.playerId, 7);
    expect(controller.textureId, 11);
    await controller.release();
  });
}
