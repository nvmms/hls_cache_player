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
  case invalidResponse(URL)

  var errorDescription: String? {
    switch self {
    case .invalidSource:
      return "cacheKey and a valid absolute url are required."
    case .unknownPlayer(let id):
      return "Unknown playerId \(id)."
    case .invalidResponse(let url):
      return "The server returned an invalid response for \(url.absoluteString)."
    }
  }
}

private final class IOSPlayerSlot {
  let id: Int
  let player: AVPlayer
  var looping = false
  var wantsToPlay = false
  var playSpeed: Float = 1.0
  var resourceLoader: IOSHLSResourceLoader?
  var timeControlObservation: NSKeyValueObservation?
  var itemStatusObservation: NSKeyValueObservation?
  var endObserver: NSObjectProtocol?
  var timeObserver: Any?
  var queue: [(mediaId: String, url: URL)] = []
  var currentMediaId: String?

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
  private var nextPlayerId = 1

  private let log = OSLog(
    subsystem: "hls_cache_player",
    category: "player"
  )

  init(emit: @escaping EventEmitter) {
    self.emit = emit
  }

  func configure(
    memoryCacheBytes: Int,
    diskCacheBytes: Int
  ) {
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

  func createPlayer() throws -> Int {
    precondition(Thread.isMainThread)
    if let slot = slots.values.first { return slot.id }
    let slot = IOSPlayerSlot(id: nextPlayerId)
    nextPlayerId += 1
    slots[slot.id] = slot
    return slot.id
  }

  func insert(mediaId: String, url: URL, at requestedIndex: Int?) throws {
    let slot = try onlySlot()
    if let existing = slot.queue.first(where: { $0.mediaId == mediaId }) {
      if existing.url == url { return }
      throw IOSVideoError.invalidSource
    }
    let index = requestedIndex ?? slot.queue.count
    guard index >= 0, index <= slot.queue.count else {
      throw IOSVideoError.invalidSource
    }
    slot.queue.insert((mediaId, url), at: index)
    emitState(slot)
  }

  func insertAll(_ items: [(String, URL)], at requestedIndex: Int?) throws {
    let slot = try onlySlot()
    let index = requestedIndex ?? slot.queue.count
    guard index >= 0, index <= slot.queue.count else {
      throw IOSVideoError.invalidSource
    }
    var accepted: [(mediaId: String, url: URL)] = []
    for item in items {
      if let existing = slot.queue.first(where: { $0.mediaId == item.0 }) {
        if existing.url == item.1 { continue }
        throw IOSVideoError.invalidSource
      }
      if let existing = accepted.first(where: { $0.mediaId == item.0 }) {
        if existing.url == item.1 { continue }
        throw IOSVideoError.invalidSource
      }
      accepted.append((mediaId: item.0, url: item.1))
    }
    slot.queue.insert(contentsOf: accepted, at: index)
    emitState(slot)
  }

  func remove(mediaId: String) throws {
    let slot = try onlySlot()
    guard let index = slot.queue.firstIndex(where: { $0.mediaId == mediaId }) else {
      throw IOSVideoError.invalidSource
    }
    slot.queue.remove(at: index)
    if slot.currentMediaId == mediaId {
      removeObservers(slot)
      slot.player.pause()
      slot.player.replaceCurrentItem(with: nil)
      slot.currentMediaId = nil
    }
    emitState(slot)
  }

  func removeAll(mediaIds: [String]) throws {
    let slot = try onlySlot()
    let ids = Set(mediaIds)
    guard ids.allSatisfy({ id in slot.queue.contains { $0.mediaId == id } })
    else { throw IOSVideoError.invalidSource }
    let removesCurrent = slot.currentMediaId.map { ids.contains($0) } ?? false
    slot.queue.removeAll { ids.contains($0.mediaId) }
    if removesCurrent {
      removeObservers(slot)
      slot.player.pause()
      slot.player.replaceCurrentItem(with: nil)
      slot.currentMediaId = nil
    }
    emitState(slot)
  }

  func playMedia(_ mediaId: String, positionMilliseconds: Int64) throws {
    let slot = try onlySlot()
    guard let entry = slot.queue.first(where: { $0.mediaId == mediaId }) else {
      throw IOSVideoError.invalidSource
    }
    if slot.currentMediaId != mediaId {
      let item = AVPlayerItem(asset: AVURLAsset(url: entry.url))
      slot.player.replaceCurrentItem(with: item)
      slot.currentMediaId = mediaId
      installObservers(slot, item: item)
    }
    let time = CMTime(value: max(0, positionMilliseconds), timescale: 1000)
    slot.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    slot.wantsToPlay = true
    slot.player.playImmediately(atRate: slot.playSpeed)
  }

  private func onlySlot() throws -> IOSPlayerSlot {
    guard let slot = slots.values.first else { throw IOSVideoError.unknownPlayer(-1) }
    return slot
  }

  func play(_ id: Int) throws {
    let slot = try playerSlot(id)
    if slot.player.currentItem?.status == .failed {
      emitError(slot, slot.player.currentItem?.error)
      return
    }
    slot.wantsToPlay = true
    slot.player.playImmediately(atRate: slot.playSpeed)
  }

  func setPlaySpeed(_ id: Int, speed: Float) throws {
    guard speed.isFinite, speed > 0 else { throw IOSVideoError.invalidSource }
    let slot = try playerSlot(id)
    slot.playSpeed = speed
    if slot.player.timeControlStatus == .playing { slot.player.rate = speed }
    emitState(slot)
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

  func releasePlayer(_ id: Int) {
    guard let slot = slots[id] else { return }
    discardSlot(slot)
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
    view.onFirstFrame = { [weak self] in self?.emitFirstFrame(id) }
    attachedViews[id] = views.map(WeakVideoView.init)
  }

  func detachView(_ id: Int, view: IOSPlayerContainerView) {
    let wasCurrent = liveViews(id).last === view
    var views = liveViews(id)
    views.removeAll { $0 === view }
    view.playerLayer.player = nil
    view.onFirstFrame = nil
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

  private func playerSlot(_ id: Int) throws -> IOSPlayerSlot {
    guard let slot = slots[id] else { throw IOSVideoError.unknownPlayer(id) }
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
          slot.player.playImmediately(atRate: slot.playSpeed)
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
        slot.player.playImmediately(atRate: slot.playSpeed)
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

  private func emitFirstFrame(_ id: Int) {
    guard let slot = slots[id], let mediaId = slot.currentMediaId else { return }
    emit([
      "playerId": id,
      "type": "firstFrame",
      "mediaId": mediaId,
    ])
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
      "cacheProgressMs": localProxy.cacheProgressMilliseconds(
        for: (item?.asset as? AVURLAsset)?.url ?? URL(fileURLWithPath: "/")
      ),
      "playSpeed": Double(slot.playSpeed),
      "videoWidth": Int(dimensions.width),
      "videoHeight": Int(dimensions.height),
      "itemStatus": item?.status.rawValue ?? -1,
      "playerStatus": slot.player.status.rawValue,
      "timeControlStatus": slot.player.timeControlStatus.rawValue,
      "waitingReason": slot.player.reasonForWaitingToPlay?.rawValue ?? "",
      "mediaId": slot.currentMediaId ?? NSNull(),
      "mediaIndex": slot.currentMediaId.flatMap { id in
        slot.queue.firstIndex(where: { $0.mediaId == id })
      } ?? -1,
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
  var onFirstFrame: (() -> Void)?
  private var readyObservation: NSKeyValueObservation?

  override init(frame: CGRect) {
    super.init(frame: frame)
    observeFirstFrame()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    observeFirstFrame()
  }

  private func observeFirstFrame() {
    readyObservation = playerLayer.observe(
      \.isReadyForDisplay,
      options: [.new]
    ) { [weak self] layer, _ in
      if layer.isReadyForDisplay { self?.onFirstFrame?() }
    }
  }
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
          subsystem: "hls_cache_player",
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
