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
    await HlsCacheProxy.dispose();
    await upstream.close(force: true);
    await cacheDirectory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  HlsVideoSource source(String id) => HlsVideoSource(
        cacheKey: id,
        url: 'http://${upstream.address.address}:${upstream.port}/$id.m3u8',
      );

  test('preload does not create or mutate a player', () async {
    final playbackUrl = await HlsCacheProxy.preload(source('preload-only'));

    expect(Uri.parse(playbackUrl).host, InternetAddress.loopbackIPv4.address);
    expect(calls.where((call) => call.method == 'createPlayer'), isEmpty);
    expect(calls.where((call) => call.method == 'addSource'), isEmpty);
    expect(calls.where((call) => call.method == 'changeSource'), isEmpty);
  });

  test('one player owns a playlist and selects by mediaId', () async {
    final player = await HlsCachePlayer.create();
    final oneUrl = await HlsCacheProxy.preload(source('one'));
    final twoUrl = await HlsCacheProxy.preload(source('two'));
    await player.addSource(mediaId: 'one', playbackUrl: oneUrl);
    await player.addSource(mediaId: 'two', playbackUrl: twoUrl);
    await player.play(mediaId: 'two');
    await player.moveTo('one');
    expect(player.playerId, 7);
    expect(player.textureId, 11);
    expect(player.playList, ['one', 'two']);
    expect(calls.where((call) => call.method == 'createPlayer'), hasLength(1));
    expect(calls.where((call) => call.method == 'moveTo'), hasLength(1));
    expect(
      calls.singleWhere((call) => call.method == 'play').arguments,
      containsPair('mediaId', 'two'),
    );
  });

  test('play resumes the current item unless restart is forced', () async {
    final player = await HlsCachePlayer.create();
    final url = await HlsCacheProxy.preload(source('one'));
    await player.addSource(mediaId: 'one', playbackUrl: url);

    await player.play(mediaId: 'one');
    await player.play(mediaId: 'one', looping: true);
    expect(calls.where((call) => call.method == 'moveTo'), isEmpty);
    expect(calls.where((call) => call.method == 'play'), hasLength(2));
    expect(
      calls.where((call) => call.method == 'setLooping').last.arguments,
      containsPair('looping', true),
    );

    await player.play(mediaId: 'one', force: true);
    expect(calls.where((call) => call.method == 'moveTo'), isEmpty);
    expect(
      calls.where((call) => call.method == 'play').last.arguments,
      containsPair('force', true),
    );
  });

  test('force restarts a standalone source atomically in native play',
      () async {
    final player = await HlsCachePlayer.create();
    final url = await HlsCacheProxy.preload(source('standalone'));
    await player.changeSource(
      mediaId: 'standalone',
      playbackUrl: url,
      autoPlay: false,
    );

    await player.play(mediaId: 'standalone', force: true);

    expect(calls.where((call) => call.method == 'moveTo'), isEmpty);
    expect(
      calls.singleWhere((call) => call.method == 'play').arguments,
      allOf(
        containsPair('mediaId', 'standalone'),
        containsPair('force', true),
      ),
    );
  });

  test('duplicate mediaId is ignored and exposes item state APIs', () async {
    final player = await HlsCachePlayer.create();
    final url = await HlsCacheProxy.preload(source('same'));

    await player.addSource(mediaId: 'same', playbackUrl: url);
    await player.addSource(mediaId: 'same', playbackUrl: url);
    await player.addSource(
      mediaId: 'same',
      playbackUrl: '$url?proxyRestart=1',
    );

    expect(player.playList, ['same']);
    expect(calls.where((call) => call.method == 'addSource'), hasLength(1));
    expect(calls.where((call) => call.method == 'updateSource'), hasLength(1));
    expect(player.stateOf('missing'), isNull);
    expect(player.stateOf('same')?.playbackState, VideoPlaybackState.idle);
    expect(
      await player.statesOf('same').first,
      same(player.stateOf('same')),
    );
  });

  test('changeSource reuses player and texture and replaces playlist',
      () async {
    final player = await HlsCachePlayer.create();
    final playlistUrl = await HlsCacheProxy.preload(source('playlist-item'));
    final standaloneUrl = await HlsCacheProxy.preload(source('standalone'));
    await player.addSource(
      mediaId: 'playlist-item',
      playbackUrl: playlistUrl,
    );
    await player.changeSource(
      mediaId: 'standalone',
      playbackUrl: standaloneUrl,
    );
    expect(player.playerId, 7);
    expect(player.textureId, 11);
    expect(player.playList, isEmpty);
    expect(calls.singleWhere((call) => call.method == 'changeSource').arguments,
        containsPair('playerId', 7));
  });
}
