# hls_cache_player example

示例使用阿里云 VOD Type A URL 鉴权。运行时注入 PrivateKey，不要将 Key
写入源码或提交到版本库：

```shell
flutter run --dart-define=VOD_AUTH_KEY=your-private-key
```

构建 release：

```shell
flutter build apk --dart-define=VOD_AUTH_KEY=your-private-key
```

`--dart-define` 可以避免 Key 被保存在仓库中，但无法让客户端内置密钥真正保密。
生产环境通常应由可信业务服务端生成短有效期播放地址。
