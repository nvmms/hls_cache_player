import Flutter
import UIKit

public final class HlsCachePlayerPlugin: NSObject, FlutterPlugin,
  FlutterStreamHandler
{
  private var eventSink: FlutterEventSink?
  private lazy var engine = IOSVideoEngine { [weak self] event in
    self?.send(event)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = HlsCachePlayerPlugin()

    let methods = FlutterMethodChannel(
      name: "hls_cache_player/methods",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methods)

    let events = FlutterEventChannel(
      name: "hls_cache_player/events",
      binaryMessenger: registrar.messenger()
    )
    events.setStreamHandler(instance)

    registrar.register(
      IOSVideoViewFactory(engine: instance.engine),
      withId: "hls_cache_player/view"
    )
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "cacheDirectory" {
      result(
        FileManager.default.urls(
          for: .cachesDirectory,
          in: .userDomainMask
        )[0].path
      )
      return
    }

    guard let arguments = call.arguments as? [String: Any] else {
      result(error("arguments", "Method arguments are required."))
      return
    }

    do {
      switch call.method {
      case "configure":
        engine.configure(
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
        engine.preload(source) { preloadResult in
          DispatchQueue.main.async {
            switch preloadResult {
            case .success(let localURL):
              result(localURL)
            case .failure(let preloadError):
              result(self.error("preload", preloadError.localizedDescription))
            }
          }
        }

      case "createPlayer":
        result(try engine.createPlayer())

      case "insert":
        try engine.insert(
          mediaId: requiredString(arguments["mediaId"]),
          url: try requiredURL(arguments["url"]),
          at: optionalInt(arguments["index"])
        )
        result(nil)

      case "insertAll":
        try engine.insertAll(
          queueItems(arguments["items"]),
          at: optionalInt(arguments["index"])
        )
        result(nil)

      case "remove":
        try engine.remove(mediaId: requiredString(arguments["mediaId"]))
        result(nil)

      case "removeAll":
        try engine.removeAll(mediaIds: arguments["mediaIds"] as? [String] ?? [])
        result(nil)

      case "playMedia":
        try engine.playMedia(
          requiredString(arguments["mediaId"]),
          positionMilliseconds: int64(arguments["positionMs"])
        )
        result(nil)

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

      case "setPlaySpeed":
        try engine.setPlaySpeed(
          playerId(arguments),
          speed: Float(arguments["speed"] as? Double ?? 1.0)
        )
        result(nil)

      case "getState":
        result(try engine.state(playerId(arguments)))

      case "release":
        engine.releasePlayer(playerId(arguments))
        result(nil)

      case "dispose":
        engine.dispose()
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(self.error("hls_cache_player", error.localizedDescription))
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

  private func requiredString(_ value: Any?) throws -> String {
    guard let value = value as? String, !value.isEmpty else {
      throw IOSVideoError.invalidSource
    }
    return value
  }

  private func requiredURL(_ value: Any?) throws -> URL {
    guard let raw = value as? String, let url = URL(string: raw) else {
      throw IOSVideoError.invalidSource
    }
    return url
  }

  private func optionalInt(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
  }

  private func queueItems(_ value: Any?) throws -> [(String, URL)] {
    guard let values = value as? [[String: Any]] else {
      throw IOSVideoError.invalidSource
    }
    return try values.map {
      (try requiredString($0["mediaId"]), try requiredURL($0["url"]))
    }
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
