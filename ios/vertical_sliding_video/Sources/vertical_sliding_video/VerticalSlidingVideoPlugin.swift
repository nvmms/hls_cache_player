import Flutter
import UIKit

public final class VerticalSlidingVideoPlugin: NSObject, FlutterPlugin,
  FlutterStreamHandler
{
  private var eventSink: FlutterEventSink?
  private lazy var engine = IOSVideoEngine { [weak self] event in
    self?.send(event)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VerticalSlidingVideoPlugin()

    let methods = FlutterMethodChannel(
      name: "vertical_sliding_video/methods",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methods)

    let events = FlutterEventChannel(
      name: "vertical_sliding_video/events",
      binaryMessenger: registrar.messenger()
    )
    events.setStreamHandler(instance)

    registrar.register(
      IOSVideoViewFactory(engine: instance.engine),
      withId: "vertical_sliding_video/view"
    )
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(error("arguments", "Method arguments are required."))
      return
    }

    do {
      switch call.method {
      case "configure":
        engine.configure(
          maxPlayers: int(arguments["maxPlayers"], fallback: 3),
          memoryCacheBytes: int(
            arguments["memoryCacheBytes"],
            fallback: 48 * 1024 * 1024
          ),
          diskCacheBytes: int(
            arguments["diskCacheBytes"],
            fallback: 768 * 1024 * 1024
          )
        )
        result(nil)

      case "preload":
        let source = try videoSource(arguments)
        engine.preload(source) { preloadError in
          DispatchQueue.main.async {
            if let preloadError {
              result(self.error("preload", preloadError.localizedDescription))
            } else {
              result(nil)
            }
          }
        }

      case "acquire":
        let source = try videoSource(arguments)
        let playerId = try engine.acquire(
          source,
          autoPlay: arguments["autoPlay"] as? Bool ?? false
        )
        result(playerId)

      case "play":
        try engine.play(playerId(arguments))
        result(nil)

      case "pause":
        try engine.pause(playerId(arguments))
        result(nil)

      case "seekTo":
        try engine.seek(
          playerId(arguments),
          positionMilliseconds: int64(arguments["positionMs"])
        )
        result(nil)

      case "setLooping":
        try engine.setLooping(
          playerId(arguments),
          looping: arguments["looping"] as? Bool ?? false
        )
        result(nil)

      case "getState":
        result(try engine.state(playerId(arguments)))

      case "release":
        engine.releaseLease(playerId(arguments))
        result(nil)

      case "dispose":
        engine.dispose()
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(self.error("vertical_sliding_video", error.localizedDescription))
    }
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func send(_ event: [String: Any]) {
    if Thread.isMainThread {
      eventSink?(event)
    } else {
      DispatchQueue.main.async { [weak self] in self?.eventSink?(event) }
    }
  }

  private func videoSource(_ arguments: [String: Any]) throws -> IOSVideoSource {
    guard
      let cacheKey = arguments["cacheKey"] as? String,
      !cacheKey.isEmpty,
      let urlString = arguments["url"] as? String,
      let url = URL(string: urlString)
    else {
      throw IOSVideoError.invalidSource
    }
    return IOSVideoSource(
      cacheKey: cacheKey,
      url: url,
      headers: arguments["headers"] as? [String: String] ?? [:]
    )
  }

  private func playerId(_ arguments: [String: Any]) -> Int {
    int(arguments["playerId"], fallback: -1)
  }

  private func int(_ value: Any?, fallback: Int = 0) -> Int {
    (value as? NSNumber)?.intValue ?? fallback
  }

  private func int64(_ value: Any?) -> Int64 {
    (value as? NSNumber)?.int64Value ?? 0
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }
}
