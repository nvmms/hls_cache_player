import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hls_cache_player/hls_cache_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hls_cache_player/methods');
  late Directory cacheDirectory;
  late HttpServer upstream;
  late Map<String, int> requests;
  late int cacheDirectoryCalls;

  setUp(() async {
    HttpOverrides.global = null;
    cacheDirectory = await Directory.systemTemp.createTemp('vsv_proxy_test_');
    requests = {};
    cacheDirectoryCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cacheDirectory') {
        cacheDirectoryCalls++;
        return cacheDirectory.path;
      }
      return null;
    });
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      requests.update(request.uri.path, (value) => value + 1,
          ifAbsent: () => 1);
      switch (request.uri.path) {
        case '/video.m3u8':
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write('''#EXTM3U
#EXT-X-TARGETDURATION:5
#EXTINF:5,
seg1.ts?auth_key=first
#EXTINF:5,
seg2.ts?auth_key=second
#EXT-X-ENDLIST
''');
          break;
        case '/seg1.ts':
          request.response.add(<int>[
            0x47,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            ...List<int>.filled(25, 1),
          ]);
          break;
        case '/seg2.ts':
          request.response.add(List<int>.filled(48, 2));
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await HlsCacheProxy.dispose();
    await upstream.close(force: true);
    await cacheDirectory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('concurrent preloads preserve every route and start one server',
      () async {
    final origin = 'http://${upstream.address.address}:${upstream.port}';
    final urls = await Future.wait(List.generate(8, (index) {
      return HlsCacheProxy.preload(HlsVideoSource(
        cacheKey: 'concurrent-video',
        url: '$origin/video.m3u8?auth_key=$index',
      ));
    }));
    expect(cacheDirectoryCalls, 1);
    expect(urls.map((url) => Uri.parse(url).port).toSet(), hasLength(1));
    expect(urls.toSet(), hasLength(1));
    final client = HttpClient();
    try {
      for (final url in urls) {
        expect(utf8.decode(await _read(client, Uri.parse(url))),
            startsWith('#EXTM3U'));
      }
    } finally {
      client.close(force: true);
    }
  });

  test('preload returns a proxy playlist and warms only the first segment',
      () async {
    final origin = 'http://${upstream.address.address}:${upstream.port}';
    final proxyUrl = await HlsCacheProxy.preload(
      HlsVideoSource(
        cacheKey: 'video-stable-key',
        url: '$origin/video.m3u8?auth_key=playlist',
      ),
    );

    expect(Uri.parse(proxyUrl).host, InternetAddress.loopbackIPv4.address);
    expect(Uri.parse(proxyUrl).path, endsWith('/video.m3u8'));
    expect(Uri.parse(proxyUrl).hasQuery, isFalse);
    expect(requests['/video.m3u8'], 1);
    expect(requests['/seg1.ts'], 1);
    expect(requests['/seg2.ts'], isNull);

    final client = HttpClient();
    final playlist = await _read(client, Uri.parse(proxyUrl));
    final lines = const LineSplitter()
        .convert(utf8.decode(playlist))
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
    expect(lines, hasLength(2));
    expect(Uri.parse(lines[0]).path, endsWith('/seg1.ts'));

    final first = await _read(client, Uri.parse(lines[0]));
    expect(first, hasLength(32));
    expect(first.take(7), <int>[0x47, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
    expect(requests['/seg1.ts'], 1, reason: 'first segment should hit cache');

    final rangeRequest = await client.getUrl(Uri.parse(lines[0]));
    rangeRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=4-11');
    final rangeResponse = await rangeRequest.close();
    expect(rangeResponse.statusCode, HttpStatus.partialContent);
    expect(rangeResponse.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 4-11/32');
    expect(
      await rangeResponse.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      ),
      <int>[0xff, 0xff, 0xff, ...List<int>.filled(5, 1)],
    );

    final second = await _read(client, Uri.parse(lines[1]));
    expect(second, List<int>.filled(48, 2));
    expect(requests['/seg2.ts'], 1);
    await _read(client, Uri.parse(lines[1]));
    expect(requests['/seg2.ts'], 1, reason: 'later segments should persist');

    final refreshedProxyUrl = await HlsCacheProxy.preload(
      HlsVideoSource(
        cacheKey: 'video-stable-key',
        url: '$origin/video.m3u8?auth_key=refreshed',
      ),
    );
    expect(refreshedProxyUrl, proxyUrl,
        reason: 'cacheKey must define a stable playback URL');
    expect(requests['/video.m3u8'], 2, reason: 'playlist signatures refresh');
    expect(requests['/seg1.ts'], 1, reason: 'stable segments remain cached');
    // Signature refresh must not invalidate URLs held by an existing player.
    await _read(client, Uri.parse(proxyUrl));
    await _read(client, Uri.parse(lines[1]));
    client.close(force: true);
  });

  test('an inactive tab can reuse its URLs after other videos are loaded',
      () async {
    final origin = 'http://${upstream.address.address}:${upstream.port}';
    final client = HttpClient();
    // Retain the playlist and segment URL as an inactive player would.
    final oldUrl = await HlsCacheProxy.preload(HlsVideoSource(
      cacheKey: 'shared-video',
      url: '$origin/video.m3u8?auth_key=old',
    ));
    try {
      final oldPlaylist = utf8.decode(await _read(client, Uri.parse(oldUrl)));
      final oldSegment = const LineSplitter().convert(oldPlaylist).firstWhere(
            (line) => line.isNotEmpty && !line.startsWith('#'),
          );
      await HlsCacheProxy.configure(
          memoryCacheBytes: 0, diskCacheBytes: 768 * 1024 * 1024);
      for (var index = 0; index < 12; index++) {
        await HlsCacheProxy.preload(HlsVideoSource(
          cacheKey: 'video-$index',
          url: '$origin/video.m3u8?auth_key=$index',
        ));
      }
      await HlsCacheProxy.preload(HlsVideoSource(
        cacheKey: 'shared-video',
        url: '$origin/video.m3u8?auth_key=new',
      ));
      // Force a cache miss as well: routes must outlive the cached bytes.
      final files =
          await Directory('${cacheDirectory.path}/hls_cache_player_proxy')
              .list()
              .where((entry) => entry is File)
              .toList();
      for (final file in files) {
        await file.delete();
      }
      expect(utf8.decode(await _read(client, Uri.parse(oldUrl))),
          startsWith('#EXTM3U'));
      expect(await _read(client, Uri.parse(oldSegment)), hasLength(32));
    } finally {
      client.close(force: true);
      await HlsCacheProxy.configure(
          memoryCacheBytes: 48 * 1024 * 1024,
          diskCacheBytes: 768 * 1024 * 1024);
    }
  });

  test('404 response identifies the missing route', () async {
    final origin = 'http://${upstream.address.address}:${upstream.port}';
    final url = Uri.parse(await HlsCacheProxy.preload(HlsVideoSource(
      cacheKey: 'diagnostics',
      url: '$origin/video.m3u8',
    )));
    final client = HttpClient();
    try {
      for (final entry in {
        '/invalid': 'invalid_path',
        '/v1/missing/resource/video.m3u8': 'source_not_registered',
        '/v1/${url.pathSegments[1]}/missing/video.m3u8':
            'resource_not_registered',
      }.entries) {
        final response =
            await (await client.getUrl(url.replace(path: entry.key))).close();
        expect(response.statusCode, HttpStatus.notFound);
        expect(await response.transform(utf8.decoder).join(),
            contains(entry.value));
      }
    } finally {
      client.close(force: true);
    }
  });
}

Future<List<int>> _read(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  expect(response.statusCode, anyOf(HttpStatus.ok, HttpStatus.partialContent));
  return response.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
}
