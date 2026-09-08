import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hls_cache_player/hls_cache_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hls_cache_player/methods');
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
    await HlsCachePlayerPool.dispose();
    await upstream.close(force: true);
    await cacheDirectory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('pool forwards only the local proxy URL to acquire', () async {
    await HlsCachePlayerPool.configure();
    final localUrl = await HlsCachePlayerPool.preload(
      HlsVideoSource(
        cacheKey: 'method-channel',
        url: 'http://${upstream.address.address}:${upstream.port}/video.m3u8',
      ),
    );
    final controller = await HlsCachePlayerPool.acquire(localUrl);

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

    final localUrl = await HlsCachePlayerPool.preload(
      HlsVideoSource(
        cacheKey: 'texture-key',
        url: 'http://${upstream.address.address}:${upstream.port}/video.m3u8',
      ),
    );
    final controller = await HlsCachePlayerPool.acquire(localUrl);

    expect(controller.playerId, 7);
    expect(controller.textureId, 11);
    await controller.release();
  });

  test('releasing and reacquiring players preserves a shared proxy URL',
      () async {
    final origin = 'http://${upstream.address.address}:${upstream.port}';
    final sharedUrl = await HlsCachePlayerPool.preload(HlsVideoSource(
      cacheKey: 'shared-tab-video',
      url: '$origin/video.m3u8',
    ));
    final tab1 = await HlsCachePlayerPool.acquire(sharedUrl);
    final tab2 = await HlsCachePlayerPool.acquire(sharedUrl);
    await tab1.release();
    await tab2.release();
    for (var index = 0; index < 8; index++) {
      final url = await HlsCachePlayerPool.preload(HlsVideoSource(
        cacheKey: 'scrolled-video-$index',
        url: '$origin/video.m3u8',
      ));
      final player = await HlsCachePlayerPool.acquire(url);
      await player.release();
    }
    final returningTab = await HlsCachePlayerPool.acquire(sharedUrl);
    final client = HttpClient();
    try {
      final response =
          await (await client.getUrl(Uri.parse(sharedUrl))).close();
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      expect(calls.where((call) => call.method == 'dispose'), isEmpty);
    } finally {
      client.close(force: true);
      await returningTab.release();
    }
  });
}
