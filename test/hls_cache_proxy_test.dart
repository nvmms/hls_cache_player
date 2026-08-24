import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vertical_sliding_video/vertical_sliding_video.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('vertical_sliding_video/methods');
  late Directory cacheDirectory;
  late HttpServer upstream;
  late Map<String, int> requests;

  setUp(() async {
    HttpOverrides.global = null;
    cacheDirectory = await Directory.systemTemp.createTemp('vsv_proxy_test_');
    requests = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cacheDirectory') return cacheDirectory.path;
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
          request.response.add(List<int>.filled(32, 1));
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
    await HlsCacheProxy.instance.dispose();
    await upstream.close(force: true);
    await cacheDirectory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('preload returns a proxy playlist and warms only the first segment',
      () async {
    final origin = 'http://${upstream.address.address}:${upstream.port}';
    final proxyUrl = await HlsCacheProxy.instance.preload(
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
    expect(first, List<int>.filled(32, 1));
    expect(requests['/seg1.ts'], 1, reason: 'first segment should hit cache');

    final second = await _read(client, Uri.parse(lines[1]));
    expect(second, List<int>.filled(48, 2));
    expect(requests['/seg2.ts'], 1);
    await _read(client, Uri.parse(lines[1]));
    expect(requests['/seg2.ts'], 1, reason: 'later segments should persist');

    await HlsCacheProxy.instance.preload(
      HlsVideoSource(
        cacheKey: 'video-stable-key',
        url: '$origin/video.m3u8?auth_key=refreshed',
      ),
    );
    expect(requests['/video.m3u8'], 2, reason: 'playlist signatures refresh');
    expect(requests['/seg1.ts'], 1, reason: 'stable segments remain cached');
    client.close(force: true);
  });
}

Future<List<int>> _read(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  expect(response.statusCode, anyOf(HttpStatus.ok, HttpStatus.partialContent));
  return response.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
}
