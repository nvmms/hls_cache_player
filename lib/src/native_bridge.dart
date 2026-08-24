import 'package:flutter/services.dart';

class NativeVideoBridge {
  NativeVideoBridge._();

  static const MethodChannel methods = MethodChannel(
    'hls_cache_player/methods',
  );
  static const EventChannel events = EventChannel(
    'hls_cache_player/events',
  );

  static final Stream<Map<Object?, Object?>> eventStream = events
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .cast<Map<Object?, Object?>>()
      .asBroadcastStream();
}
