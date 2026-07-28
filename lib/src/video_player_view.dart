import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'video_controller.dart';

class VerticalVideoPlayer extends StatelessWidget {
  const VerticalVideoPlayer({
    required this.controller,
    this.fit = BoxFit.cover,
    super.key,
  });

  final VerticalVideoController controller;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final creationParams = <String, Object>{
      'playerId': controller.playerId,
      'fit': fit.name,
    };
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AndroidView(
        viewType: 'vertical_sliding_video/view',
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.iOS => UiKitView(
        viewType: 'vertical_sliding_video/view',
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      _ => const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text(
            'vertical_sliding_video supports Android and iOS.',
            style: TextStyle(color: Colors.white),
          ),
        ),
      ),
    };
  }
}
