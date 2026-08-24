import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'native_bridge.dart';
import 'video_models.dart';

/// Process-local HLS cache exposed through a loopback HTTP server.
///
/// A returned URL may be handed to this package's player or any other player
/// capable of loading an ordinary HTTP HLS URL in the same app process.
final class HlsCacheProxy {
  HlsCacheProxy._();

  static final HlsCacheProxy instance = HlsCacheProxy._();

  final HttpClient _client = HttpClient();
  final Map<String, _RegisteredSource> _sources = {};
  final Map<String, Future<Uint8List>> _inFlight = {};
  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();
  HttpServer? _server;
  Directory? _directory;
  int _memoryBytes = 48 * 1024 * 1024;
  int _diskBytes = 768 * 1024 * 1024;
  int _memoryUsed = 0;

  Future<void> configure({
    required int memoryCacheBytes,
    required int diskCacheBytes,
  }) async {
    _memoryBytes = memoryCacheBytes;
    _diskBytes = diskCacheBytes;
    _trimMemory();
    if (_server != null) unawaited(_trimDisk());
  }

  /// Caches the entry/media playlists and the first playable resources.
  /// Returns a loopback HLS URL whose resource identity is namespaced by the
  /// caller-provided [HlsVideoSource.cacheKey].
  Future<String> preload(HlsVideoSource source) async {
    await _ensureStarted();
    final token = sha256.convert(utf8.encode(source.cacheKey)).toString();
    final registered = _RegisteredSource(token: token, source: source);
    _sources[token] = registered;

    final entry = Uri.parse(source.url);
    final entryBytes = await _load(registered, entry, refresh: true);
    final entryText = utf8.decode(entryBytes, allowMalformed: true);
    final variant = _firstVariant(entryText, entry);
    final mediaUri = variant ?? entry;
    final mediaBytes = variant == null
        ? entryBytes
        : await _load(registered, mediaUri, refresh: true);
    final mediaText = utf8.decode(mediaBytes, allowMalformed: true);
    final startup = _startupResources(mediaText, mediaUri);
    await Future.wait(startup.map((uri) => _load(registered, uri)));

    final localUri = _proxyUri(registered, entry);
    await _verifyLocalUri(localUri);
    return localUri.toString();
  }

  Future<void> dispose() async {
    await _server?.close(force: true);
    _server = null;
    _sources.clear();
    _inFlight.clear();
    _memory.clear();
    _memoryUsed = 0;
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    final root = await NativeVideoBridge.methods.invokeMethod<String>(
      'cacheDirectory',
    );
    if (root == null || root.isEmpty) {
      throw StateError('Native platform did not return a cache directory.');
    }
    _directory = Directory('$root/vertical_sliding_video_proxy');
    await _directory!.create(recursive: true);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_serve, onError: (Object error, StackTrace stack) {
      stderr.writeln('vertical_sliding_video proxy: $error');
    });
  }

  Future<void> _verifyLocalUri(Uri uri) async {
    final request = await _client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'Local proxy returned HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    await response.drain<void>();
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      final parts = request.uri.pathSegments;
      if (parts.length != 4 || parts[0] != 'v1') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final source = _sources[parts[1]];
      final upstream = source?.routes[parts[2]];
      if (source == null || upstream == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final original = await _load(source, upstream);
      final isPlaylist = _isPlaylist(upstream, original);
      final bytes = isPlaylist
          ? Uint8List.fromList(
              utf8.encode(_rewritePlaylist(source, upstream, original)),
            )
          : original;
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        _contentType(upstream, isPlaylist),
      );
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      final range = _parseRange(
          request.headers.value(HttpHeaders.rangeHeader), bytes.length);
      if (range != null) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.$1}-${range.$2}/${bytes.length}',
        );
        request.response.contentLength = range.$2 - range.$1 + 1;
        if (request.method != 'HEAD') {
          request.response.add(bytes.sublist(range.$1, range.$2 + 1));
        }
      } else {
        request.response.contentLength = bytes.length;
        if (request.method != 'HEAD') request.response.add(bytes);
      }
      await request.response.close();
    } catch (error, stack) {
      final message = 'HLS proxy failed for ${request.method} '
          '${request.uri}: $error';
      developer.log(
        message,
        name: 'vertical_sliding_video',
        error: error,
        stackTrace: stack,
        level: 1000,
      );
      request.response.statusCode = HttpStatus.badGateway;
      request.response.headers.contentType = ContentType.text;
      request.response.write(message);
      await request.response.close();
    }
  }

  Future<Uint8List> _load(
    _RegisteredSource source,
    Uri uri, {
    bool refresh = false,
  }) {
    final key = _resourceKey(source.source.cacheKey, uri);
    if (!refresh) {
      final memory = _memory.remove(key);
      if (memory != null) {
        _memory[key] = memory;
        return Future.value(memory);
      }
    }
    return _inFlight.putIfAbsent(key, () async {
      try {
        final file = File('${_directory!.path}/$key');
        if (!refresh && await file.exists()) {
          final bytes = await file.readAsBytes();
          unawaited(file.setLastModified(DateTime.now()));
          _putMemory(key, bytes);
          return bytes;
        }
        final request = await _client.getUrl(uri);
        source.source.headers.forEach(request.headers.set);
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.drain<void>();
          throw HttpException('HTTP ${response.statusCode} for $uri', uri: uri);
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        await file.writeAsBytes(bytes, flush: false);
        _putMemory(key, bytes);
        unawaited(_trimDisk());
        return bytes;
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  void _putMemory(String key, Uint8List bytes) {
    final previous = _memory.remove(key);
    if (previous != null) _memoryUsed -= previous.length;
    _memory[key] = bytes;
    _memoryUsed += bytes.length;
    _trimMemory();
  }

  void _trimMemory() {
    while (_memoryUsed > _memoryBytes && _memory.isNotEmpty) {
      final key = _memory.keys.first;
      _memoryUsed -= _memory.remove(key)!.length;
    }
  }

  Future<void> _trimDisk() async {
    final directory = _directory;
    if (directory == null) return;
    final files = await directory
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    final entries = <(File, FileStat)>[];
    var total = 0;
    for (final file in files) {
      final stat = await file.stat();
      entries.add((file, stat));
      total += stat.size;
    }
    entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final entry in entries) {
      if (total <= _diskBytes) break;
      await entry.$1.delete();
      total -= entry.$2.size;
    }
  }

  Uri _proxyUri(_RegisteredSource source, Uri upstream) {
    final resourceToken = sha256
        .convert(utf8.encode(upstream.toString()))
        .toString()
        .substring(0, 24);
    source.routes[resourceToken] = upstream;
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: _server!.port,
      pathSegments: [
        'v1',
        source.token,
        resourceToken,
        upstream.pathSegments.lastOrNull ?? 'resource',
      ],
    );
  }

  String _rewritePlaylist(
    _RegisteredSource source,
    Uri playlistUri,
    Uint8List bytes,
  ) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.split('\n').map((raw) {
      final line = raw.trim();
      if (line.startsWith('#')) {
        return line.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (match) {
          final resolved = playlistUri.resolve(match.group(1)!);
          return 'URI="${_proxyUri(source, resolved)}"';
        });
      }
      if (line.isEmpty) return raw;
      return _proxyUri(source, playlistUri.resolve(line)).toString();
    }).join('\n');
  }

  String _resourceKey(String namespace, Uri uri) {
    // Signed query parameters deliberately do not participate in identity.
    // The caller changes cacheKey when bytes behind a stable resource change.
    final identity =
        '${uri.scheme}://${uri.host}:${uri.hasPort ? uri.port : 0}${uri.path}';
    return sha256.convert(utf8.encode('$namespace\n$identity')).toString();
  }

  Uri? _firstVariant(String playlist, Uri base) {
    final lines = const LineSplitter().convert(playlist);
    for (var index = 0; index < lines.length - 1; index++) {
      if (lines[index].startsWith('#EXT-X-STREAM-INF')) {
        return base.resolve(lines[index + 1].trim());
      }
    }
    return null;
  }

  List<Uri> _startupResources(String playlist, Uri base) {
    final resources = <Uri>[];
    var expectsSegment = false;
    for (final raw in const LineSplitter().convert(playlist)) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-MAP') || line.startsWith('#EXT-X-KEY')) {
        final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (match != null) resources.add(base.resolve(match.group(1)!));
      } else if (line.startsWith('#EXTINF')) {
        expectsSegment = true;
      } else if (expectsSegment && line.isNotEmpty && !line.startsWith('#')) {
        resources.add(base.resolve(line));
        break;
      }
    }
    return resources;
  }

  bool _isPlaylist(Uri uri, Uint8List bytes) {
    if (uri.path.toLowerCase().endsWith('.m3u8')) return true;
    const marker = <int>[0x23, 0x45, 0x58, 0x54, 0x4d, 0x33, 0x55];
    if (bytes.length < marker.length) return false;
    for (var index = 0; index < marker.length; index++) {
      if (bytes[index] != marker[index]) return false;
    }
    return true;
  }

  String _contentType(Uri uri, bool playlist) {
    if (playlist) return 'application/vnd.apple.mpegurl';
    return switch (uri.pathSegments.lastOrNull?.split('.').last.toLowerCase()) {
      'ts' || 'm2ts' => 'video/mp2t',
      'mp4' || 'm4s' || 'm4v' => 'video/mp4',
      'aac' => 'audio/aac',
      'vtt' => 'text/vtt',
      _ => 'application/octet-stream',
    };
  }

  (int, int)? _parseRange(String? value, int length) {
    final match =
        value == null ? null : RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
    if (match == null) return null;
    final startText = match.group(1)!;
    final endText = match.group(2)!;
    if (startText.isEmpty) {
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return null;
      return ((length - suffix).clamp(0, length - 1), length - 1);
    }
    final start = int.tryParse(startText);
    final end = endText.isEmpty ? length - 1 : int.tryParse(endText);
    if (start == null || end == null || start >= length || start > end) {
      return null;
    }
    return (start, end.clamp(start, length - 1));
  }
}

final class _RegisteredSource {
  _RegisteredSource({required this.token, required this.source});

  final String token;
  final HlsVideoSource source;
  final Map<String, Uri> routes = {};
}

extension<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
