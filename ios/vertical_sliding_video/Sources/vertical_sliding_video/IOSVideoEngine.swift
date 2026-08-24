import AVFoundation
import Flutter
import os.log
import UIKit

struct IOSVideoSource {
  let cacheKey: String
  let url: URL
  let headers: [String: String]
}

enum IOSVideoError: LocalizedError {
  case invalidSource
  case unknownPlayer(Int)
  case poolExhausted
  case invalidResponse(URL)

  var errorDescription: String? {
    switch self {
    case .invalidSource:
      return "cacheKey and a valid absolute url are required."
    case .unknownPlayer(let id):
      return "Unknown playerId \(id)."
    case .poolExhausted:
      return "All player pool entries are leased."
    case .invalidResponse(let url):
      return "The server returned an invalid response for \(url.absoluteString)."
    }
  }
}

private final class IOSPlayerSlot {
  let id: Int
  let player: AVPlayer
  var cacheKey: String?
  var leases = 0
  var lastUsed = Date()
  var looping = false
  var wantsToPlay = false
  var resourceLoader: IOSHLSResourceLoader?
  var timeControlObservation: NSKeyValueObservation?
  var itemStatusObservation: NSKeyValueObservation?
  var endObserver: NSObjectProtocol?
  var timeObserver: Any?

  init(id: Int) {
    self.id = id
    player = AVPlayer()
    player.automaticallyWaitsToMinimizeStalling = false
  }
}

final class IOSVideoEngine {
  typealias EventEmitter = ([String: Any]) -> Void

  private let emit: EventEmitter
  private let cache = IOSHLSCache()
  private lazy var localProxy = IOSLocalHLSProxy(cache: cache)
  private var slots: [Int: IOSPlayerSlot] = [:]
  private var attachedViews: [Int: [WeakVideoView]] = [:]
  private var maxPlayers = 3
  private var nextPlayerId = 1

  private let log = OSLog(
    subsystem: "vertical_sliding_video",
    category: "player"
  )

  init(emit: @escaping EventEmitter) {
    self.emit = emit
  }

  func configure(
    maxPlayers: Int,
    memoryCacheBytes: Int,
    diskCacheBytes: Int
  ) {
    self.maxPlayers = max(1, maxPlayers)
    cache.configure(
      memoryCacheBytes: memoryCacheBytes,
      diskCacheBytes: diskCacheBytes
    )
  }

  func preload(
    _ source: IOSVideoSource,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    localProxy.preload(source, completion: completion)
  }

  func acquire(_ source: IOSVideoSource, autoPlay: Bool) throws -> Int {
    precondition(Thread.isMainThread)

    if let existing = slots.values.first(where: {
      $0.cacheKey == source.cacheKey
    }) {
      existing.leases += 1
      existing.lastUsed = Date()
      if autoPlay {
        existing.wantsToPlay = true
        existing.player.play()
      }
      return existing.id
    }

    let slot = try obtainSlot()
    slot.cacheKey = source.cacheKey
    slot.leases = 1
    slot.lastUsed = Date()
    slot.wantsToPlay = autoPlay

    // Playback uses the loopback URL returned by preload. AVPlayer requests
    // playlist resources on demand and the native proxy serves cached bytes or
    // fetches missing segments from the signed upstream URL.
    let assetOptions: [String: Any] = source.headers.isEmpty
      ? [:]
      : ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
    let asset = AVURLAsset(url: source.url, options: assetOptions)
    let item = AVPlayerItem(asset: asset)
    slot.player.replaceCurrentItem(with: item)
    installObservers(slot, item: item)

    if autoPlay { slot.player.play() }
    return slot.id
  }

  func play(_ id: Int) throws {
    let slot = try playerSlot(id)
    if slot.player.currentItem?.status == .failed {
      emitError(slot, slot.player.currentItem?.error)
      return
    }
    slot.wantsToPlay = true
    slot.player.play()
  }

  func pause(_ id: Int) throws {
    let slot = try playerSlot(id)
    slot.wantsToPlay = false
    slot.player.pause()
  }

  func seek(_ id: Int, positionMilliseconds: Int64) throws {
    let time = CMTime(value: max(0, positionMilliseconds), timescale: 1000)
    try playerSlot(id).player.seek(
      to: time,
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
  }

  func setLooping(_ id: Int, looping: Bool) throws {
    let slot = try playerSlot(id)
    slot.looping = looping
  }

  func state(_ id: Int) throws -> [String: Any] {
    state(try playerSlot(id))
  }

  func releaseLease(_ id: Int) {
    guard let slot = slots[id] else { return }
    slot.leases = max(0, slot.leases - 1)
    slot.lastUsed = Date()
    guard slot.leases == 0 else { return }
    slot.wantsToPlay = false
    slot.player.pause()
    if slots.count > maxPlayers { discardSlot(slot) }
  }

  private func discardSlot(_ slot: IOSPlayerSlot) {
    removeObservers(slot)
    slot.resourceLoader?.cancelAll()
    slot.resourceLoader = nil
    slot.player.replaceCurrentItem(with: nil)
    for view in liveViews(slot.id) {
      view.playerLayer.player = nil
    }
    attachedViews.removeValue(forKey: slot.id)
    slots.removeValue(forKey: slot.id)
  }

  func attachView(_ id: Int, view: IOSPlayerContainerView) throws {
    let slot = try playerSlot(id)
    var views = liveViews(id)
    views.removeAll { $0 === view }
    if let previous = views.last {
      previous.playerLayer.player = nil
    }
    views.append(view)
    view.playerLayer.player = slot.player
    attachedViews[id] = views.map(WeakVideoView.init)
  }

  func detachView(_ id: Int, view: IOSPlayerContainerView) {
    let wasCurrent = liveViews(id).last === view
    var views = liveViews(id)
    views.removeAll { $0 === view }
    view.playerLayer.player = nil
    if wasCurrent, let slot = slots[id], let target = views.last {
      target.playerLayer.player = slot.player
    }
    attachedViews[id] = views.map(WeakVideoView.init)
    if views.isEmpty { attachedViews.removeValue(forKey: id) }
  }

  func dispose() {
    precondition(Thread.isMainThread)
    for slot in slots.values {
      removeObservers(slot)
      slot.player.pause()
      slot.player.replaceCurrentItem(with: nil)
    }
    for views in attachedViews.values {
      views.forEach { $0.value?.playerLayer.player = nil }
    }
    slots.removeAll()
    attachedViews.removeAll()
    localProxy.stop()
  }

  private func obtainSlot() throws -> IOSPlayerSlot {
    if slots.count < maxPlayers {
      let slot = IOSPlayerSlot(id: nextPlayerId)
      nextPlayerId += 1
      slots[slot.id] = slot
      return slot
    }

    guard let slot = slots.values
      .filter({ $0.leases == 0 })
      .min(by: { $0.lastUsed < $1.lastUsed })
    else {
      // maxPlayers controls the warm players retained by the pool. A Flutter
      // scrollable may transiently mount more children than that, so create an
      // overflow player instead of failing the visible video's acquire. The
      // overflow is discarded when its final lease is released.
      let slot = IOSPlayerSlot(id: nextPlayerId)
      nextPlayerId += 1
      slots[slot.id] = slot
      return slot
    }
    removeObservers(slot)
    slot.player.pause()
    slot.player.replaceCurrentItem(with: nil)
    slot.resourceLoader?.cancelAll()
    slot.resourceLoader = nil
    slot.cacheKey = nil
    return slot
  }

  private func playerSlot(_ id: Int) throws -> IOSPlayerSlot {
    guard let slot = slots[id] else { throw IOSVideoError.unknownPlayer(id) }
    slot.lastUsed = Date()
    return slot
  }

  private func installObservers(_ slot: IOSPlayerSlot, item: AVPlayerItem) {
    removeObservers(slot)

    slot.timeControlObservation = slot.player.observe(
      \.timeControlStatus,
      options: [.initial, .new]
    ) { [weak self, weak slot] _, _ in
      guard let self, let slot else { return }
      self.emitState(slot)
    }

    slot.itemStatusObservation = item.observe(
      \.status,
      options: [.initial, .new]
    ) { [weak self, weak slot] item, _ in
      guard let self, let slot else { return }
      if item.status == .failed {
        self.emitError(slot, item.error)
      } else {
        if item.status == .readyToPlay, slot.wantsToPlay {
          slot.player.play()
        }
        self.emitState(slot)
      }
    }

    slot.endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self, weak slot] _ in
      guard let self, let slot else { return }
      if slot.looping {
        slot.player.seek(to: .zero)
        slot.player.play()
      } else {
        self.emitState(slot, ended: true)
      }
    }

    slot.timeObserver = slot.player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 4),
      queue: .main
    ) { [weak self, weak slot] _ in
      guard let self, let slot else { return }
      self.emitState(slot)
    }
  }

  private func removeObservers(_ slot: IOSPlayerSlot) {
    slot.timeControlObservation?.invalidate()
    slot.timeControlObservation = nil
    slot.itemStatusObservation?.invalidate()
    slot.itemStatusObservation = nil
    if let observer = slot.endObserver {
      NotificationCenter.default.removeObserver(observer)
      slot.endObserver = nil
    }
    if let observer = slot.timeObserver {
      slot.player.removeTimeObserver(observer)
      slot.timeObserver = nil
    }
  }

  private func emitState(_ slot: IOSPlayerSlot, ended: Bool = false) {
    emit(state(slot, ended: ended))
  }

  private func state(
    _ slot: IOSPlayerSlot,
    ended: Bool = false
  ) -> [String: Any] {
    let item = slot.player.currentItem
    if item?.status == .failed || slot.player.status == .failed {
      return errorEvent(slot, item?.error ?? slot.player.error)
    }
    let playbackState: Int
    if ended {
      playbackState = 4
    } else if slot.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
      playbackState = 2
    } else if item?.status == .readyToPlay {
      playbackState = 3
    } else {
      playbackState = 1
    }
    let dimensions = item?.presentationSize ?? .zero
    return [
      "playerId": slot.id,
      "type": "state",
      "playbackState": playbackState,
      "isPlaying": slot.player.timeControlStatus == .playing,
      "positionMs": milliseconds(slot.player.currentTime()),
      "durationMs": milliseconds(item?.duration ?? .zero),
      "bufferedPositionMs": milliseconds(
        item?.loadedTimeRanges.last?.timeRangeValue.end ?? .zero
      ),
      "videoWidth": Int(dimensions.width),
      "videoHeight": Int(dimensions.height),
      "itemStatus": item?.status.rawValue ?? -1,
      "playerStatus": slot.player.status.rawValue,
      "timeControlStatus": slot.player.timeControlStatus.rawValue,
      "waitingReason": slot.player.reasonForWaitingToPlay?.rawValue ?? "",
    ]
  }

  private func emitError(_ slot: IOSPlayerSlot, _ error: Error?) {
    let event = errorEvent(slot, error)
    os_log(
      "Player %{public}d failed: %{public}@",
      log: log,
      type: .error,
      slot.id,
      event["message"] as? String ?? "AVPlayer failed."
    )
    emit(event)
  }

  private func errorEvent(
    _ slot: IOSPlayerSlot,
    _ error: Error?
  ) -> [String: Any] {
    let nsError = error as NSError?
    var message = error?.localizedDescription ?? "AVPlayer failed."
    if let reason = nsError?.localizedFailureReason, !reason.isEmpty {
      message += " \(reason)"
    }
    if let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError {
      message += " underlying=\(underlying.domain):\(underlying.code)"
      if let description = underlying.userInfo[NSLocalizedDescriptionKey] {
        message += " \(description)"
      }
    }
    return [
      "playerId": slot.id,
      "type": "error",
      "message": message,
      "domain": nsError?.domain ?? "AVFoundationErrorDomain",
      "code": nsError?.code ?? 0,
    ]
  }

  private func milliseconds(_ time: CMTime) -> Int64 {
    guard time.isNumeric else { return 0 }
    return Int64(max(0, CMTimeGetSeconds(time) * 1000))
  }

  private func liveViews(_ id: Int) -> [IOSPlayerContainerView] {
    attachedViews[id]?.compactMap(\.value) ?? []
  }
}

private final class WeakVideoView {
  weak var value: IOSPlayerContainerView?
  init(_ value: IOSPlayerContainerView) { self.value = value }
}

final class IOSPlayerContainerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private final class IOSVideoPlatformView: NSObject, FlutterPlatformView {
  private let engine: IOSVideoEngine
  private let playerId: Int
  private let container: IOSPlayerContainerView

  init(
    frame: CGRect,
    engine: IOSVideoEngine,
    playerId: Int,
    fit: String
  ) {
    self.engine = engine
    self.playerId = playerId
    container = IOSPlayerContainerView(frame: frame)
    super.init()
    container.backgroundColor = .black
    container.playerLayer.videoGravity =
      fit == "contain" ? .resizeAspect : .resizeAspectFill
    do {
      try engine.attachView(playerId, view: container)
    } catch {
      os_log(
        "Unable to attach platform view to player %{public}d: %{public}@",
        log: OSLog(
          subsystem: "vertical_sliding_video",
          category: "player"
        ),
        type: .error,
        playerId,
        error.localizedDescription
      )
    }
  }

  func view() -> UIView { container }

  deinit {
    engine.detachView(playerId, view: container)
  }
}

final class IOSVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  private let engine: IOSVideoEngine

  init(engine: IOSVideoEngine) {
    self.engine = engine
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let arguments = args as? [String: Any] ?? [:]
    return IOSVideoPlatformView(
      frame: frame,
      engine: engine,
      playerId: (arguments["playerId"] as? NSNumber)?.intValue ?? -1,
      fit: arguments["fit"] as? String ?? "cover"
    )
  }
}
