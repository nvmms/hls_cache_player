import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'video_controller.dart';

class HlsPlayerView extends StatelessWidget {
  const HlsPlayerView({
    required this.controller,
    this.fit = BoxFit.cover,
    super.key,
  });

  final HlsPlayerController controller;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final creationParams = <String, Object>{
      'playerId': controller.playerId,
      'fit': fit.name,
    };
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => _AndroidTexturePlayer(
          controller: controller,
          fit: fit,
        ),
      TargetPlatform.iOS => UiKitView(
          viewType: 'hls_cache_player/view',
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        ),
      _ => const ColoredBox(
          color: Colors.black,
          child: Center(
            child: Text(
              'hls_cache_player supports Android and iOS.',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
    };
  }
}

class _AndroidTexturePlayer extends StatelessWidget {
  const _AndroidTexturePlayer({required this.controller, required this.fit});

  final HlsPlayerController controller;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final textureId = controller.textureId;
    if (textureId == null) return const ColoredBox(color: Colors.black);
    return ColoredBox(
      color: Colors.black,
      child: ClipRect(
        child: ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, value, child) {
            if (value.videoWidth <= 0 || value.videoHeight <= 0) {
              return Texture(textureId: textureId);
            }
            return FittedBox(
              fit: fit,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: value.videoWidth.toDouble(),
                height: value.videoHeight.toDouble(),
                child: Texture(textureId: textureId),
              ),
            );
          },
        ),
      ),
    );
  }
}
