import 'package:flutter/material.dart';
import 'package:vertical_sliding_video/vertical_sliding_video.dart';

import 'aliyun_type_a_signer.dart';
import 'pooled_video_feed.dart';

const _vodAuthKey = String.fromEnvironment('VOD_AUTH_KEY');

const videoUrls = <String>[
  'https://vod.gbtjkj.top/0062f712146971f1bfd6752281fd0102/4aebcd319fdd46f03a2c655c6042f90e-sd-m3u8-shortvideo-bitrate.m3u8',
  'https://vod.gbtjkj.top/0062f712146971f1bfd6752281fd0102/58e1f3d664ef4452a6d7b4f600b8a3b1-878cc6f5f38efcd1c37f6c084f7801b8-sd.m3u8',
  'https://vod.gbtjkj.top/10a63ba507b971f19bab1777b3df0102/00717e632a7d44f59f5b326d9b8e3538-2bf1abcc996ae9d789c877852f89a1fc-sd.m3u8',
  'https://vod.gbtjkj.top/d0a7656907b971f19383752281fd0102/709e7bb79f6b4a0fbc686b7414dedc0b-446080a51b4d225b5c512d4897dfc9f6-sd.m3u8',
  'https://vod.gbtjkj.top/002d414c07b971f180010666a2ec0102/06db9cb9f0f14b33ab168fd341020e4c-dbb604f810eb23f0384550df8005df4b-sd.m3u8',
  'https://vod.gbtjkj.top/505f7ca307b871f18fa91776b3cf0102/23e36795ec7e4869aabbe09d2734b172-7d8a0de88b0e0d65dfb6267f5863a9b9-sd.m3u8',
  'https://vod.gbtjkj.top/f05659bd03ec71f1aa7a1777b3ce0102/f88bd0a041004108a7344a2ce380204a-9d66f0800d88200c5af9959b45f0695e-sd.m3u8',
  'https://vod.gbtjkj.top/80fadee302ea71f1bfe21777b3de0102/ffefc3e4ed6246bcacc17088d63e5cd8-85e540edb712d1395ce22a4771949061-sd.m3u8',
  'https://vod.gbtjkj.top/10b7ec6ffd0a71f0804e752281ec0102/179733092d2e49e4b7ec6cf8e604cc42-8ce505e6c61f5f85fe25312a6381196d-sd.m3u8',
  'https://vod.gbtjkj.top/10e9e011ebd171f08260752281fc0102/9c11370f20a04bf8be817b89b20a5c18-ca2b71cd5d622b841052e47c58909c41-sd-m3u8-shortvideo-bitrate.m3u8',
  'https://vod.gbtjkj.top/5039ba72ebcf71f08260752281fc0102/d6c259b408b4487c8872b8fc54cba4e7-af5bf38d230f994323ffe293e6fddf02-sd-m3u8-shortvideo-bitrate.m3u8',
  'https://vod.gbtjkj.top/00f2d224ebce71f08260752281fc0102/86ba82f2ac9e413ca862e475d69f783e-443c0ff3e8aca55820efe408b728a43e-sd-m3u8-shortvideo-bitrate.m3u8',
];

late final List<HlsVideoSource> videos;

String createAuthKey(String url) {
  return createAliyunTypeAAuthUrl(url: url, privateKey: _vodAuthKey);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (_vodAuthKey.isEmpty) {
    throw StateError(
      '缺少阿里云 VOD 鉴权 Key。请使用 '
      '--dart-define=VOD_AUTH_KEY=<your-key> 运行 example。',
    );
  }

  videos = videoUrls.take(10).map((url) {
    final cacheKey = Uri.parse(
      url,
    ).replace(queryParameters: const {}).toString();
    return HlsVideoSource(
      cacheKey: cacheKey,
      url: createAuthKey(url),
    );
  }).toList(growable: false);

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: PooledPostListPage(videos: videos),
    );
  }
}
