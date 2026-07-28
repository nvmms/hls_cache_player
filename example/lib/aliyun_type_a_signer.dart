import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Creates an Alibaba Cloud VOD Type A signed URL.
///
/// Existing query parameters are preserved, while an old `auth_key` is
/// replaced. The already percent-encoded URL path is used for signing.
String createAliyunTypeAAuthUrl({
  required String url,
  required String privateKey,
  int? timestamp,
  String rand = '0',
  String uid = '0',
}) {
  if (privateKey.isEmpty) {
    throw ArgumentError.value(privateKey, 'privateKey', 'must not be empty');
  }
  if (rand.contains('-') || uid.contains('-')) {
    throw ArgumentError('rand and uid must not contain a hyphen.');
  }

  final uri = Uri.parse(url);
  if (!uri.hasScheme || uri.host.isEmpty || uri.path.isEmpty) {
    throw ArgumentError.value(url, 'url', 'must be an absolute media URL');
  }

  final signedAt = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final stringToSign = '${uri.path}-$signedAt-$rand-$uid-$privateKey';
  final hash = md5.convert(utf8.encode(stringToSign)).toString();
  final authKey = '$signedAt-$rand-$uid-$hash';
  final query = Map<String, String>.of(uri.queryParameters)
    ..remove('auth_key')
    ..['auth_key'] = authKey;

  return uri.replace(queryParameters: query).toString();
}
