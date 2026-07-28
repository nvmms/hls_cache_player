import 'package:flutter/services.dart';

class NativeVideoBridge {
  NativeVideoBridge._();

  static const MethodChannel methods = MethodChannel(
    'vertical_sliding_video/methods',
  );
  static const EventChannel events = EventChannel(
    'vertical_sliding_video/events',
  );

  static final Stream<Map<Object?, Object?>> eventStream = events
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .cast<Map<Object?, Object?>>()
      .asBroadcastStream();
}
