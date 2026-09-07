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
      if (call.method == 'createPlayer') return 7;
      if (call.method == 'cacheDirectory') return cacheDirectory.path;
      return null;
    });
  });

  tearDown(() async {
    await HlsCachePlayer.dispose();
    await upstream.close(force: true);
    await cacheDirectory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('controller forwards queue insertion and playback by mediaId', () async {
    await HlsCachePlayer.configure();
    final localUrl = await HlsCachePlayer.preload(
      HlsVideoSource(
        cacheKey: 'method-channel',
        url: 'http://${upstream.address.address}:${upstream.port}/video.m3u8',
      ),
    );
    final controller = await HlsCachePlayer.createController();
    final item = HlsQueueItem(mediaId: 'video-1', url: localUrl);
    await Future.wait([controller.insert(item), controller.insert(item)]);
    await controller.playMedia('video-1');
    await controller.remove('video-1');

    final insert = calls.firstWhere((call) => call.method == 'insert');
    expect(calls.where((call) => call.method == 'insert'), hasLength(1));
    expect(insert.arguments, {
      'playerId': 7,
      'mediaId': 'video-1',
      'url': localUrl,
    });
    final play = calls.firstWhere((call) => call.method == 'playMedia');
    expect(play.arguments, {
      'playerId': 7,
      'mediaId': 'video-1',
      'positionMs': 0,
    });
    final remove = calls.firstWhere((call) => call.method == 'remove');
    expect(remove.arguments, {
      'playerId': 7,
      'mediaId': 'video-1',
    });
    await controller.release();
  });

  test('factory accepts an Android texture create response', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'createPlayer') {
        return <String, Object>{'playerId': 7, 'textureId': 11};
      }
      if (call.method == 'cacheDirectory') return cacheDirectory.path;
      return null;
    });

    final controller = await HlsCachePlayer.createController();

    expect(controller.playerId, 7);
    expect(controller.textureId, 11);
    await controller.release();
  });
  test('controllers route independent queues and release by playerId',
      () async {
    var nextId = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'createPlayer') {
        final id = ++nextId;
        return {'playerId': id, 'textureId': id + 100};
      }
      if (call.method == 'cacheDirectory') return cacheDirectory.path;
      return null;
    });
    final a = await HlsCachePlayer.createController();
    final b = await HlsCachePlayer.createController(looping: false);
    expect(identical(a, b), isFalse);
    expect(a.playerId, isNot(b.playerId));
    expect(a.textureId, isNot(b.textureId));
    expect(calls.where((c) => c.method == 'createPlayer'), hasLength(2));
    for (final controller in [a, b]) {
      final url = 'http://127.0.0.1/${controller.playerId}.m3u8';
      await controller.insert(HlsQueueItem(mediaId: 'same-id', url: url));
      await controller.playMedia('same-id');
      await controller.insertAll([HlsQueueItem(mediaId: 'extra', url: url)]);
      await controller.removeAll(['extra']);
      await controller.remove('same-id');
    }
    for (final method in [
      'insert',
      'insertAll',
      'playMedia',
      'remove',
      'removeAll'
    ]) {
      expect(
          calls
              .where((c) => c.method == method)
              .map((c) => (c.arguments as Map)['playerId']),
          [a.playerId, b.playerId]);
    }
    await a.release();
    await b.play();
    expect(calls.last.arguments, {'playerId': b.playerId});
    await b.release();
    expect(
        calls
            .where((c) => c.method == 'release')
            .map((c) => (c.arguments as Map)['playerId']),
        [a.playerId, b.playerId]);
  });
  test('ordinary playback does not insert and can switch back to a queue',
      () async {
    final controller = await HlsCachePlayer.createController();
    await controller.setUrl('https://example.com/direct.m3u8',
        position: const Duration(seconds: 2));
    final load = calls.last;
    expect(load.method, 'setUrl');
    expect(load.arguments, {
      'playerId': controller.playerId,
      'url': 'https://example.com/direct.m3u8',
      'autoPlay': false,
      'positionMs': 2000,
    });
    expect(calls.where((c) => c.method == 'insert'), isEmpty);
    expect(controller.value.mediaId, isNull);
    expect(controller.value.mediaIndex, -1);
    await controller.play();
    expect(calls.last.method, 'play');
    await controller.insert(const HlsQueueItem(
        mediaId: 'queued', url: 'http://127.0.0.1/queued.m3u8'));
    await controller.playMedia('queued');
    await controller.playUrl('https://example.com/other.m3u8');
    expect(calls.last.method, 'setUrl');
    expect((calls.last.arguments as Map)['autoPlay'], isTrue);
    await controller.playMedia('queued');
    expect(calls.last.method, 'playMedia');
    expect((calls.last.arguments as Map)['mediaId'], 'queued');
    await controller.release();
  });

  test('setSource resolves a cached URL without inserting a queue item',
      () async {
    final controller = await HlsCachePlayer.createController();
    await controller.setSource(
        HlsVideoSource(
          cacheKey: 'ordinary',
          url: 'http://${upstream.address.address}:${upstream.port}/video.m3u8',
        ),
        autoPlay: true);
    expect(calls.last.method, 'setUrl');
    expect(
        (calls.last.arguments as Map)['url'], startsWith('http://127.0.0.1:'));
    expect((calls.last.arguments as Map)['autoPlay'], isTrue);
    expect(calls.where((c) => c.method == 'insert' || c.method == 'insertAll'),
        isEmpty);
    await controller.release();
  });

  test('ordinary playback rejects invalid URLs before invoking native code',
      () async {
    final controller = await HlsCachePlayer.createController();
    final count = calls.length;
    for (final url in ['', 'relative.m3u8', 'file:///tmp/video.m3u8']) {
      await expectLater(controller.setUrl(url), throwsArgumentError);
    }
    expect(calls, hasLength(count));
    await controller.release();
    await expectLater(
        controller.playUrl('https://example.com/video.m3u8'), throwsStateError);
  });
}
