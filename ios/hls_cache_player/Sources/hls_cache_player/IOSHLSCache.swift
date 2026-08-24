import AVFoundation
import CryptoKit
import Foundation

final class IOSHLSCache {
  typealias DataResult = Result<Data, Error>

  private let memory = NSCache<NSString, NSData>()
  private let stateQueue = DispatchQueue(label: "hls_cache_player.cache.state")
  private let ioQueue = DispatchQueue(
    label: "hls_cache_player.cache.io",
    qos: .utility,
    attributes: .concurrent
  )
  private var inFlight: [String: [(DataResult) -> Void]] = [:]
  private var diskLimit = 768 * 1024 * 1024

  private lazy var directory: URL = {
    let root = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    )[0]
    let value = root.appendingPathComponent(
      "hls_cache_player",
      isDirectory: true
    )
    try? FileManager.default.createDirectory(
      at: value,
      withIntermediateDirectories: true
    )
    return value
  }()

  func configure(memoryCacheBytes: Int, diskCacheBytes: Int) {
    memory.totalCostLimit = max(1024 * 1024, memoryCacheBytes)
    diskLimit = max(16 * 1024 * 1024, diskCacheBytes)
    trimDisk()
  }

  func preload(
    _ source: IOSVideoSource,
    completion: @escaping (Error?) -> Void
  ) {
    data(
      cacheKey: source.cacheKey,
      url: source.url,
      headers: source.headers,
      refresh: true
    ) { result in
      switch result {
      case .failure(let error):
        completion(error)
      case .success(let entryPlaylist):
        self.preloadMediaPlaylist(
          entryPlaylist,
          playlistURL: source.url,
          source: source,
          completion: completion
        )
      }
    }
  }

  func data(
    cacheKey: String,
    url: URL,
    headers: [String: String],
    refresh: Bool = false,
    completion: @escaping (DataResult) -> Void
  ) {
    let key = namespacedKey(cacheKey: cacheKey, url: url)
    if !refresh, let cached = memory.object(forKey: key as NSString) {
      completion(.success(cached as Data))
      return
    }

    let fileURL = diskURL(for: key)
    ioQueue.async {
      if !refresh, let diskData = try? Data(contentsOf: fileURL) {
        self.memory.setObject(
          diskData as NSData,
          forKey: key as NSString,
          cost: diskData.count
        )
        try? FileManager.default.setAttributes(
          [.modificationDate: Date()],
          ofItemAtPath: fileURL.path
        )
        completion(.success(diskData))
        return
      }
      self.startOrJoinNetworkRequest(
        key: key,
        fileURL: fileURL,
        url: url,
        headers: headers,
        completion: completion
      )
    }
  }

  private func startOrJoinNetworkRequest(
    key: String,
    fileURL: URL,
    url: URL,
    headers: [String: String],
    completion: @escaping (DataResult) -> Void
  ) {
    let shouldStart: Bool = stateQueue.sync {
      if inFlight[key] != nil {
        inFlight[key]?.append(completion)
        return false
      }
      inFlight[key] = [completion]
      return true
    }
    guard shouldStart else { return }

    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    URLSession.shared.dataTask(with: request) { data, response, error in
      let result: DataResult
      if let error {
        result = .failure(error)
      } else if
        let http = response as? HTTPURLResponse,
        (200...299).contains(http.statusCode),
        let data
      {
        self.memory.setObject(
          data as NSData,
          forKey: key as NSString,
          cost: data.count
        )
        try? data.write(to: fileURL, options: .atomic)
        self.trimDisk()
        result = .success(data)
      } else {
        result = .failure(IOSVideoError.invalidResponse(url))
      }

      let callbacks: [(DataResult) -> Void] = self.stateQueue.sync {
        self.inFlight.removeValue(forKey: key) ?? []
      }
      callbacks.forEach { $0(result) }
    }.resume()
  }

  private func preloadMediaPlaylist(
    _ playlist: Data,
    playlistURL: URL,
    source: IOSVideoSource,
    completion: @escaping (Error?) -> Void
  ) {
    if let variant = firstVariantURL(playlist, baseURL: playlistURL) {
      data(
        cacheKey: source.cacheKey,
        url: variant,
        headers: source.headers,
        refresh: true
      ) { result in
        switch result {
        case .failure(let error):
          completion(error)
        case .success(let mediaPlaylist):
          self.preloadStartupResources(
            mediaPlaylist,
            playlistURL: variant,
            source: source,
            completion: completion
          )
        }
      }
      return
    }
    preloadStartupResources(
      playlist,
      playlistURL: playlistURL,
      source: source,
      completion: completion
    )
  }

  private func preloadStartupResources(
    _ playlist: Data,
    playlistURL: URL,
    source: IOSVideoSource,
    completion: @escaping (Error?) -> Void
  ) {
    let resources = startupURLs(playlist, baseURL: playlistURL)
    guard !resources.isEmpty else {
      completion(nil)
      return
    }

    let group = DispatchGroup()
    let errorLock = NSLock()
    var firstError: Error?
    for resource in resources {
      group.enter()
      data(
        cacheKey: source.cacheKey,
        url: resource,
        headers: source.headers
      ) { result in
        if case .failure(let error) = result {
          errorLock.lock()
          if firstError == nil { firstError = error }
          errorLock.unlock()
        }
        group.leave()
      }
    }
    group.notify(queue: ioQueue) { completion(firstError) }
  }

  private func firstVariantURL(_ data: Data, baseURL: URL) -> URL? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: .newlines)
    for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF") {
      guard index + 1 < lines.count else { continue }
      let value = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty, !value.hasPrefix("#") {
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
      }
    }
    return nil
  }

  private func startupURLs(_ data: Data, baseURL: URL) -> [URL] {
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    var resources: [URL] = []
    var expectsMediaSegment = false

    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("#EXT-X-MAP") || line.hasPrefix("#EXT-X-KEY") {
        if
          let reference = quotedURI(in: line),
          let url = URL(string: reference, relativeTo: baseURL)?.absoluteURL
        {
          resources.append(url)
        }
      } else if line.hasPrefix("#EXTINF") {
        expectsMediaSegment = true
      } else if
        expectsMediaSegment,
        !line.isEmpty,
        !line.hasPrefix("#"),
        let url = URL(string: line, relativeTo: baseURL)?.absoluteURL
      {
        resources.append(url)
        break
      }
    }
    return resources
  }

  private func quotedURI(in line: String) -> String? {
    guard
      let marker = line.range(of: "URI=\""),
      let end = line[marker.upperBound...].firstIndex(of: "\"")
    else {
      return nil
    }
    return String(line[marker.upperBound..<end])
  }

  private func namespacedKey(cacheKey: String, url: URL) -> String {
    var canonical = URLComponents(url: url, resolvingAgainstBaseURL: false)
    canonical?.query = nil
    canonical?.fragment = nil
    return "\(cacheKey):\((canonical?.url ?? url).absoluteString.sha256)"
  }

  private func diskURL(for key: String) -> URL {
    directory.appendingPathComponent(key.sha256, isDirectory: false)
  }

  private func trimDisk() {
    ioQueue.async(flags: .barrier) {
      let keys: Set<URLResourceKey> = [
        .fileSizeKey,
        .contentModificationDateKey,
      ]
      guard
        let files = try? FileManager.default.contentsOfDirectory(
          at: self.directory,
          includingPropertiesForKeys: Array(keys),
          options: [.skipsHiddenFiles]
        )
      else {
        return
      }

      var entries: [(url: URL, bytes: Int, date: Date)] = files.compactMap {
        url in
        guard let values = try? url.resourceValues(forKeys: keys) else {
          return nil
        }
        return (
          url,
          values.fileSize ?? 0,
          values.contentModificationDate ?? .distantPast
        )
      }
      var total = entries.reduce(0) { $0 + $1.bytes }
      entries.sort { $0.date < $1.date }
      for entry in entries where total > self.diskLimit {
        try? FileManager.default.removeItem(at: entry.url)
        total -= entry.bytes
      }
    }
  }
}

final class IOSHLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  let loaderQueue = DispatchQueue(
    label: "hls_cache_player.resource_loader",
    qos: .userInitiated
  )
  let assetURL: URL

  private let source: IOSVideoSource
  private let cache: IOSHLSCache
  private var cancelledRequests: Set<ObjectIdentifier> = []

  init(source: IOSVideoSource, cache: IOSHLSCache) {
    self.source = source
    self.cache = cache
    assetURL = Self.proxyURL(
      originalURL: source.url,
      cacheKey: source.cacheKey
    )
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest:
      AVAssetResourceLoadingRequest
  ) -> Bool {
    guard
      let proxyURL = loadingRequest.request.url,
      let originalURL = Self.originalURL(from: proxyURL)
    else {
      loadingRequest.finishLoading(with: IOSVideoError.invalidSource)
      return false
    }

    let identifier = ObjectIdentifier(loadingRequest)
    cache.data(
      cacheKey: source.cacheKey,
      url: originalURL,
      headers: source.headers
    ) { [weak self, weak loadingRequest] result in
      guard let self, let loadingRequest else { return }
      self.loaderQueue.async {
        guard self.cancelledRequests.remove(identifier) == nil else { return }
        switch result {
        case .failure(let error):
          loadingRequest.finishLoading(with: error)
        case .success(let originalData):
          let data = self.isPlaylist(originalData, url: originalURL)
            ? self.rewritePlaylist(originalData, baseURL: originalURL)
            : originalData
          self.respond(
            loadingRequest,
            data: data,
            sourceURL: originalURL
          )
        }
      }
    }
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    cancelledRequests.insert(ObjectIdentifier(loadingRequest))
  }

  func cancelAll() {
    loaderQueue.async { self.cancelledRequests.removeAll() }
  }

  private func respond(
    _ request: AVAssetResourceLoadingRequest,
    data: Data,
    sourceURL: URL
  ) {
    if let information = request.contentInformationRequest {
      let detectedType = contentType(for: sourceURL, data: data)
      // AVFoundation may constrain the accepted types for an individual
      // request. Supplying an unsupported generic type (for example
      // public.data for an MPEG-2 transport stream) makes HLS parsing fail.
      if
        let allowedTypes = information.allowedContentTypes,
        !allowedTypes.isEmpty,
        !allowedTypes.contains(detectedType)
      {
        information.contentType = nil
      } else {
        information.contentType = detectedType
      }
      information.contentLength = Int64(data.count)
      information.isByteRangeAccessSupported = true
    }

    if let dataRequest = request.dataRequest {
      let requestedOffset = max(
        dataRequest.requestedOffset,
        dataRequest.currentOffset
      )
      let start = max(0, Int(requestedOffset))
      let end = min(data.count, start + dataRequest.requestedLength)
      if start < end {
        dataRequest.respond(with: data.subdata(in: start..<end))
      }
    }
    request.finishLoading()
  }

  private func contentType(for url: URL, data: Data) -> String {
    if isPlaylist(data, url: url) { return "public.m3u-playlist" }

    switch url.pathExtension.lowercased() {
    case "ts", "m2ts":
      return "public.mpeg-2-transport-stream"
    case "mp4", "m4s", "m4v":
      return "public.mpeg-4"
    case "aac":
      return "public.aac-audio"
    case "mp3":
      return "public.mp3"
    case "vtt", "webvtt":
      return "public.webvtt"
    default:
      return "public.data"
    }
  }

  private func rewritePlaylist(_ data: Data, baseURL: URL) -> Data {
    guard let text = String(data: data, encoding: .utf8) else { return data }
    let rewritten = text.components(separatedBy: .newlines).map { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("#") {
        return rewriteQuotedURI(line, baseURL: baseURL)
      }
      guard
        !line.isEmpty,
        let resourceURL = URL(string: line, relativeTo: baseURL)?.absoluteURL
      else {
        return rawLine
      }
      return Self.proxyURL(
        originalURL: resourceURL,
        cacheKey: source.cacheKey
      ).absoluteString
    }.joined(separator: "\n")
    return rewritten.data(using: .utf8) ?? data
  }

  private func rewriteQuotedURI(_ line: String, baseURL: URL) -> String {
    guard
      let marker = line.range(of: "URI=\""),
      let end = line[marker.upperBound...].firstIndex(of: "\""),
      let resourceURL = URL(
        string: String(line[marker.upperBound..<end]),
        relativeTo: baseURL
      )?.absoluteURL
    else {
      return line
    }
    let proxy = Self.proxyURL(
      originalURL: resourceURL,
      cacheKey: source.cacheKey
    ).absoluteString
    return line.replacingCharacters(
      in: marker.upperBound..<end,
      with: proxy
    )
  }

  private func isPlaylist(_ data: Data, url: URL) -> Bool {
    url.pathExtension.lowercased() == "m3u8"
      || String(data: data.prefix(7), encoding: .utf8) == "#EXTM3U"
  }

  private static func proxyURL(originalURL: URL, cacheKey: String) -> URL {
    var components = URLComponents()
    components.scheme = "vsv-cache"
    components.host = "resource"
    components.path = "/\(originalURL.lastPathComponent)"
    components.queryItems = [
      URLQueryItem(name: "url", value: originalURL.absoluteString),
      URLQueryItem(name: "key", value: cacheKey),
    ]
    return components.url!
  }

  private static func originalURL(from proxyURL: URL) -> URL? {
    URLComponents(url: proxyURL, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first(where: { $0.name == "url" })?
      .value
      .flatMap(URL.init(string:))
  }
}

extension String {
  var sha256: String {
    SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
