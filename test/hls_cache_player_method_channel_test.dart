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
    cacheDirectory = await Directory.systemTemp.createTemp('vsv_player_test_');
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      request.response.write(request.uri.path.endsWith('.m3u8')
          ? '#EXTM3U\n#EXTINF:1,\none.ts\n#EXT-X-ENDLIST\n'
          : 'segment');
      await request.response.close();
    });
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'createPlayer') {
        return <String, Object>{'playerId': 7, 'textureId': 11};
      }
      if (call.method == 'cacheDirectory') {
        return cacheDirectory.path;
      }
      if (call.method == 'getState') {
        return <String, Object>{};
      }
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

  HlsVideoSource source(String id) => HlsVideoSource(
        cacheKey: id,
        url: 'http://${upstream.address.address}:${upstream.port}/$id.m3u8',
      );

  test('one player owns a playlist and selects by id or index', () async {
    final player = await HlsCachePlayer.create();
    await player.addSource(source('one'));
    await player.addSource(source('two'));
    await player.play('two');
    await player.moveTo(0);
    expect(player.playerId, 7);
    expect(player.textureId, 11);
    expect(player.playList.map((item) => item.cacheKey), ['one', 'two']);
    expect(calls.where((call) => call.method == 'createPlayer'), hasLength(1));
    expect(calls.where((call) => call.method == 'moveTo'), hasLength(2));
  });

  test('changeSource reuses player and texture and replaces playlist',
      () async {
    final player = await HlsCachePlayer.create();
    await player.addSource(source('playlist-item'));
    await player.changeSource(source('standalone'));
    expect(player.playerId, 7);
    expect(player.textureId, 11);
    expect(player.playList, isEmpty);
    expect(calls.singleWhere((call) => call.method == 'changeSource').arguments,
        containsPair('playerId', 7));
  });
}
