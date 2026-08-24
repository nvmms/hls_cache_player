import CryptoKit
import Foundation
import Network

final class IOSLocalHLSProxy {
  private struct Route {
    let source: IOSVideoSource
    let url: URL
  }

  private let cache: IOSHLSCache
  private let queue = DispatchQueue(label: "vertical_sliding_video.http_proxy")
  private var listener: NWListener?
  private var port: UInt16?
  private var startCallbacks: [(Result<UInt16, Error>) -> Void] = []
  private var routes: [String: Route] = [:]

  init(cache: IOSHLSCache) {
    self.cache = cache
  }

  func preload(
    _ source: IOSVideoSource,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    cache.preload(source) { error in
      if let error {
        completion(.failure(error))
        return
      }
      self.ensureStarted { result in
        switch result {
        case .failure(let error):
          completion(.failure(error))
        case .success(let port):
          self.queue.async {
            let url = self.proxyURL(source: source, resourceURL: source.url, port: port)
            completion(.success(url.absoluteString))
          }
        }
      }
    }
  }

  func stop() {
    queue.sync {
      listener?.cancel()
      listener = nil
      port = nil
      routes.removeAll()
    }
  }

  private func ensureStarted(
    _ completion: @escaping (Result<UInt16, Error>) -> Void
  ) {
    queue.async {
      if let port = self.port {
        completion(.success(port))
        return
      }
      self.startCallbacks.append(completion)
      guard self.listener == nil else { return }
      do {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
          self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          self.queue.async {
            switch state {
            case .ready:
              guard let rawPort = listener.port?.rawValue else { return }
              self.port = rawPort
              let callbacks = self.startCallbacks
              self.startCallbacks.removeAll()
              callbacks.forEach { $0(.success(rawPort)) }
            case .failed(let error):
              let callbacks = self.startCallbacks
              self.startCallbacks.removeAll()
              self.listener = nil
              callbacks.forEach { $0(.failure(error)) }
            default:
              break
            }
          }
        }
        listener.start(queue: self.queue)
      } catch {
        let callbacks = self.startCallbacks
        self.startCallbacks.removeAll()
        self.listener = nil
        callbacks.forEach { $0(.failure(error)) }
      }
    }
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    receiveRequest(connection, accumulated: Data())
  }

  private func receiveRequest(
    _ connection: NWConnection,
    accumulated: Data
  ) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 64 * 1024
    ) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var request = accumulated
      if let data { request.append(data) }
      if request.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
        self.process(connection, request: request)
      } else if error == nil {
        self.receiveRequest(connection, accumulated: request)
      } else {
        connection.cancel()
      }
    }
  }

  private func process(_ connection: NWConnection, request: Data) {
    guard
      let text = String(data: request, encoding: .utf8),
      let requestLine = text.components(separatedBy: "\r\n").first
    else {
      send(connection, status: 400, type: "text/plain", body: Data())
      return
    }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else {
      send(connection, status: 400, type: "text/plain", body: Data())
      return
    }
    let method = String(parts[0])
    let target = String(parts[1])
    guard
      method == "GET" || method == "HEAD",
      let components = URLComponents(string: "http://localhost\(target)"),
      components.path.split(separator: "/").count == 4
    else {
      send(connection, status: 404, type: "text/plain", body: Data())
      return
    }
    let path = components.path.split(separator: "/").map(String.init)
    let routeKey = "\(path[1])/\(path[2])"
    guard let route = routes[routeKey] else {
      send(connection, status: 404, type: "text/plain", body: Data())
      return
    }
    let range = parseRange(text)
    cache.data(
      cacheKey: route.source.cacheKey,
      url: route.url,
      headers: route.source.headers
    ) { [weak self] result in
      guard let self else { return }
      self.queue.async {
        switch result {
        case .failure(let error):
          NSLog(
            "vertical_sliding_video proxy upstream failure %@: %@",
            route.url.absoluteString,
            error.localizedDescription
          )
          self.send(connection, status: 502, type: "text/plain", body: Data())
        case .success(let original):
          let playlist = self.isPlaylist(original, url: route.url)
          let body = playlist
            ? self.rewritePlaylist(original, baseURL: route.url, source: route.source)
            : original
          self.send(
            connection,
            status: 200,
            type: self.contentType(route.url, playlist: playlist),
            body: method == "HEAD" ? Data() : body,
            totalLength: body.count,
            range: range
          )
        }
      }
    }
  }

  private func send(
    _ connection: NWConnection,
    status: Int,
    type: String,
    body: Data,
    totalLength: Int? = nil,
    range: (Int, Int)? = nil
  ) {
    let sourceLength = totalLength ?? body.count
    let selected: Data
    let responseStatus: Int
    var extra = ""
    if let range, !body.isEmpty {
      let start = min(max(0, range.0), body.count)
      let end = min(max(start, range.1), body.count - 1)
      selected = start < body.count ? body.subdata(in: start..<(end + 1)) : Data()
      responseStatus = 206
      extra = "Content-Range: bytes \(start)-\(end)/\(sourceLength)\r\n"
    } else {
      selected = body
      responseStatus = status
    }
    let reason = responseStatus == 200 ? "OK" : responseStatus == 206
      ? "Partial Content" : "Error"
    let advertisedLength = body.isEmpty && sourceLength > 0 ? sourceLength : selected.count
    let headers = "HTTP/1.1 \(responseStatus) \(reason)\r\n"
      + "Content-Type: \(type)\r\n"
      + "Content-Length: \(advertisedLength)\r\n"
      + "Accept-Ranges: bytes\r\n"
      + "Connection: close\r\n"
      + extra
      + "\r\n"
    var response = Data(headers.utf8)
    response.append(selected)
    connection.send(content: response, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private func proxyURL(
    source: IOSVideoSource,
    resourceURL: URL,
    port: UInt16
  ) -> URL {
    let sourceToken = source.cacheKey.sha256
    let resourceToken = String(resourceURL.absoluteString.sha256.prefix(24))
    routes["\(sourceToken)/\(resourceToken)"] = Route(source: source, url: resourceURL)
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = Int(port)
    components.path = "/v1/\(sourceToken)/\(resourceToken)/\(resourceURL.lastPathComponent)"
    return components.url!
  }

  private func rewritePlaylist(
    _ data: Data,
    baseURL: URL,
    source: IOSVideoSource
  ) -> Data {
    guard let text = String(data: data, encoding: .utf8), let port else { return data }
    let rewritten = text.components(separatedBy: .newlines).map { raw in
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("#") {
        guard
          let marker = line.range(of: "URI=\""),
          let end = line[marker.upperBound...].firstIndex(of: "\""),
          let url = URL(
            string: String(line[marker.upperBound..<end]),
            relativeTo: baseURL
          )?.absoluteURL
        else { return line }
        return line.replacingCharacters(
          in: marker.upperBound..<end,
          with: proxyURL(source: source, resourceURL: url, port: port).absoluteString
        )
      }
      guard !line.isEmpty, let url = URL(string: line, relativeTo: baseURL)?.absoluteURL
      else { return raw }
      return proxyURL(source: source, resourceURL: url, port: port).absoluteString
    }.joined(separator: "\n")
    return Data(rewritten.utf8)
  }

  private func parseRange(_ request: String) -> (Int, Int)? {
    for line in request.components(separatedBy: "\r\n") {
      guard line.lowercased().hasPrefix("range: bytes=") else { continue }
      let value = line.dropFirst("range: bytes=".count).split(separator: "-", maxSplits: 1)
      guard let start = Int(value.first ?? "") else { return nil }
      return (start, value.count > 1 ? Int(value[1]) ?? Int.max : Int.max)
    }
    return nil
  }

  private func isPlaylist(_ data: Data, url: URL) -> Bool {
    url.pathExtension.lowercased() == "m3u8"
      || String(data: data.prefix(7), encoding: .utf8) == "#EXTM3U"
  }

  private func contentType(_ url: URL, playlist: Bool) -> String {
    if playlist { return "application/vnd.apple.mpegurl" }
    switch url.pathExtension.lowercased() {
    case "ts", "m2ts": return "video/mp2t"
    case "mp4", "m4s", "m4v": return "video/mp4"
    case "aac": return "audio/aac"
    case "vtt": return "text/vtt"
    default: return "application/octet-stream"
    }
  }
}
