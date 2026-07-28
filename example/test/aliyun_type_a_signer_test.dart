import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vertical_sliding_video_example/aliyun_type_a_signer.dart';

void main() {
  test('matches the Alibaba Cloud Type A signing formula', () {
    final signed = createAliyunTypeAAuthUrl(
      url: 'http://example.aliyundoc.com/video/standard/test.mp4',
      privateKey: 'aliyunvodexp1234',
      timestamp: 1627747200,
    );
    final expectedHash = md5
        .convert(
          '/video/standard/test.mp4-1627747200-0-0-aliyunvodexp1234'
              .codeUnits,
        )
        .toString();

    expect(
      Uri.parse(signed).queryParameters['auth_key'],
      '1627747200-0-0-$expectedHash',
    );
  });

  test('replaces auth_key and preserves other query parameters', () {
    final signed = createAliyunTypeAAuthUrl(
      url: 'https://vod.example.com/a.m3u8?quality=sd&auth_key=expired',
      privateKey: 'secret',
      timestamp: 100,
    );
    final query = Uri.parse(signed).queryParameters;

    expect(query['quality'], 'sd');
    expect(query['auth_key'], startsWith('100-0-0-'));
  });
}
