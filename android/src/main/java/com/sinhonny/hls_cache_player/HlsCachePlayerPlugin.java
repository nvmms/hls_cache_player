package com.sinhonny.hls_cache_player;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.view.Surface;

import androidx.annotation.NonNull;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.VideoSize;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.datasource.TransferListener;
import androidx.media3.datasource.cache.CacheDataSource;
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor;
import androidx.media3.datasource.cache.SimpleCache;
import androidx.media3.datasource.okhttp.OkHttpDataSource;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.hls.HlsMediaSource;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

/** Native Media3 implementation and bounded player/cache pools. */
@UnstableApi
public final class HlsCachePlayerPlugin
    implements FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
  private MethodChannel methods;
  private EventChannel events;
  private EventChannel.EventSink eventSink;
  private VideoEngine engine;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    engine = new VideoEngine(
        binding.getApplicationContext(), binding.getTextureRegistry(), this::emit);
    methods = new MethodChannel(binding.getBinaryMessenger(), "hls_cache_player/methods");
    methods.setMethodCallHandler(this);
    events = new EventChannel(binding.getBinaryMessenger(), "hls_cache_player/events");
    events.setStreamHandler(this);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    try {
      switch (call.method) {
        case "configure":
          engine.configure(number(call, "maxPlayers", 3).intValue(),
              number(call, "memoryCacheBytes", 48L * 1024 * 1024).longValue(),
              number(call, "diskCacheBytes", 768L * 1024 * 1024).longValue());
          result.success(null);
          break;
        case "cacheDirectory":
          result.success(engine.cacheDirectory());
          break;
        case "preload":
          engine.preload(
              required(call, "cacheKey"),
              required(call, "url"),
              headers(call),
              () -> mainHandler.post(() -> result.success(null)),
              error -> mainHandler.post(
                  () -> result.error("preload", error.getMessage(), null)));
          break;
        case "acquire":
          int playerId = engine.acquire(
              required(call, "url"), Boolean.TRUE.equals(call.argument("autoPlay")));
          Map<String, Object> acquired = new LinkedHashMap<>();
          acquired.put("playerId", playerId);
          acquired.put("textureId", engine.textureId(playerId));
          result.success(acquired);
          break;
        case "play":
          engine.player(number(call, "playerId", -1).intValue()).play();
          result.success(null);
          break;
        case "pause":
          engine.player(number(call, "playerId", -1).intValue()).pause();
          result.success(null);
          break;
        case "seekTo":
          engine.player(number(call, "playerId", -1).intValue())
              .seekTo(number(call, "positionMs", 0).longValue());
          result.success(null);
          break;
        case "setLooping":
          engine.player(number(call, "playerId", -1).intValue()).setRepeatMode(
              Boolean.TRUE.equals(call.argument("looping"))
                  ? Player.REPEAT_MODE_ONE : Player.REPEAT_MODE_OFF);
          result.success(null);
          break;
        case "getState":
          result.success(engine.state(number(call, "playerId", -1).intValue()));
          break;
        case "release":
          engine.releaseLease(number(call, "playerId", -1).intValue());
          result.success(null);
          break;
        case "dispose":
          engine.dispose();
          result.success(null);
          break;
        default:
          result.notImplemented();
      }
    } catch (Exception error) {
      result.error("hls_cache_player", error.getMessage(), null);
    }
  }

  private static Number number(MethodCall call, String name, Number fallback) {
    Number value = call.argument(name);
    return value == null ? fallback : value;
  }

  private static String required(MethodCall call, String name) {
    String value = call.argument(name);
    if (value == null || value.isEmpty()) throw new IllegalArgumentException(name + " is required");
    return value;
  }

  @SuppressWarnings("unchecked")
  private static Map<String, String> headers(MethodCall call) {
    Object raw = call.argument("headers");
    if (!(raw instanceof Map)) return Collections.emptyMap();
    Map<String, String> output = new LinkedHashMap<>();
    ((Map<Object, Object>) raw).forEach(
        (key, value) -> output.put(String.valueOf(key), String.valueOf(value)));
    return output;
  }

  private void emit(Map<String, Object> event) {
    if (Looper.myLooper() == Looper.getMainLooper()) {
      if (eventSink != null) eventSink.success(event);
      return;
    }
    mainHandler.post(() -> {
      if (eventSink != null) eventSink.success(event);
    });
  }

  @Override public void onListen(Object arguments, EventChannel.EventSink sink) { eventSink = sink; }
  @Override public void onCancel(Object arguments) { eventSink = null; }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    methods.setMethodCallHandler(null);
    events.setStreamHandler(null);
    engine.dispose();
  }

  private interface EventEmitter { void emit(Map<String, Object> event); }

  private static final class PlayerSlot {
    final int id;
    final ExoPlayer player;
    final TextureRegistry.SurfaceTextureEntry texture;
    final Surface surface;
    String cacheKey;
    int leases;
    long lastUsed;
    PlayerSlot(
        int id,
        ExoPlayer player,
        TextureRegistry.SurfaceTextureEntry texture,
        Surface surface) {
      this.id = id;
      this.player = player;
      this.texture = texture;
      this.surface = surface;
    }
  }

  private static final class VideoEngine {
    private static final long PROGRESS_INTERVAL_MS = 250;
    private final Context context;
    private final TextureRegistry textures;
    private final EventEmitter emitter;
    private final OkHttpClient http = new OkHttpClient();
    private final ExecutorService workers = Executors.newFixedThreadPool(2);
    private final Map<Integer, PlayerSlot> slots = new LinkedHashMap<>();
    private final MemoryStore memory = new MemoryStore(48L * 1024 * 1024);
    private SimpleCache disk;
    private int maxPlayers = 3;
    private int nextId = 1;
    private long configuredDiskBytes = 768L * 1024 * 1024;
    private final Handler progressHandler = new Handler(Looper.getMainLooper());
    private boolean progressScheduled;
    private final Runnable progressTicker = new Runnable() {
      @Override public void run() {
        progressScheduled = false;
        boolean hasPlayingPlayer = false;
        for (PlayerSlot slot : slots.values()) {
          if (slot.player.isPlaying()) {
            emitState(slot.id, slot.player);
            hasPlayingPlayer = true;
          }
        }
        if (hasPlayingPlayer) scheduleProgress();
      }
    };

    VideoEngine(Context context, TextureRegistry textures, EventEmitter emitter) {
      this.context = context;
      this.textures = textures;
      this.emitter = emitter;
    }

    String cacheDirectory() { return context.getCacheDir().getAbsolutePath(); }

    synchronized void configure(int players, long memoryBytes, long diskBytes) {
      int normalizedPlayers = Math.max(1, players);
      long normalizedMemoryBytes = Math.max(1024 * 1024, memoryBytes);
      long normalizedDiskBytes = Math.max(16L * 1024 * 1024, diskBytes);
      if (disk != null) {
        // A Flutter hot restart recreates Dart static state without recreating
        // this native engine. Treat the repeated configuration as idempotent.
        if (configuredDiskBytes != normalizedDiskBytes) {
          throw new IllegalStateException(
              "diskCacheBytes cannot be changed after preload/acquire");
        }
        maxPlayers = normalizedPlayers;
        memory.setMaxBytes(normalizedMemoryBytes);
        return;
      }
      maxPlayers = normalizedPlayers;
      memory.setMaxBytes(normalizedMemoryBytes);
      configuredDiskBytes = normalizedDiskBytes;
    }

    synchronized int acquire(String url, boolean autoPlay) {
      PlayerSlot slot = null;
      for (PlayerSlot item : slots.values()) {
        if (url.equals(item.cacheKey)) { slot = item; break; }
      }
      boolean needsMedia = slot == null;
      if (slot == null) slot = obtainSlot();
      slot.cacheKey = url;
      slot.leases++;
      slot.lastUsed = System.nanoTime();
      if (needsMedia) {
        DataSource.Factory localProxy = new DefaultDataSource.Factory(context);
        HlsMediaSource mediaSource = new HlsMediaSource.Factory(localProxy)
            .createMediaSource(MediaItem.fromUri(url));
        slot.player.setMediaSource(mediaSource);
        slot.player.prepare();
      }
      if (autoPlay) slot.player.play();
      return slot.id;
    }

    private PlayerSlot obtainSlot() {
      if (slots.size() < maxPlayers) return createSlot();
      PlayerSlot oldest = null;
      for (PlayerSlot slot : slots.values()) {
        if (slot.leases == 0 && (oldest == null || slot.lastUsed < oldest.lastUsed)) oldest = slot;
      }
      // maxPlayers is the number of players retained by the warm pool, not a
      // hard acquire limit. Flutter scrollables can transiently keep more
      // children mounted than their visible/preload window. Let those leases
      // use overflow players and discard them as soon as they become idle.
      if (oldest == null) return createSlot();
      oldest.player.stop();
      oldest.player.clearMediaItems();
      return oldest;
    }

    private PlayerSlot createSlot() {
      int id = nextId++;
      ExoPlayer player = new ExoPlayer.Builder(context).build();
      TextureRegistry.SurfaceTextureEntry texture = textures.createSurfaceTexture();
      Surface surface = new Surface(texture.surfaceTexture());
      player.setVideoSurface(surface);
      PlayerSlot slot = new PlayerSlot(id, player, texture, surface);
      player.addListener(new Player.Listener() {
        @Override public void onPlaybackStateChanged(int state) { emitState(id, player); }
        @Override public void onIsPlayingChanged(boolean playing) {
          emitState(id, player);
          if (playing) scheduleProgress();
        }
        @Override public void onPositionDiscontinuity(
            Player.PositionInfo oldPosition,
            Player.PositionInfo newPosition,
            int reason) {
          emitState(id, player);
        }
        @Override public void onVideoSizeChanged(VideoSize size) {
          if (size.width > 0 && size.height > 0) {
            texture.surfaceTexture().setDefaultBufferSize(size.width, size.height);
          }
          emitState(id, player);
        }
        @Override public void onPlayerError(PlaybackException error) {
          Map<String, Object> event = event(id, "error");
          event.put("message", errorWithCauses(error));
          emitter.emit(event);
        }
      });
      slots.put(id, slot);
      return slot;
    }

    synchronized long textureId(int id) {
      PlayerSlot slot = slots.get(id);
      if (slot == null) throw new IllegalArgumentException("unknown playerId " + id);
      return slot.texture.id();
    }

    private void emitState(int id, ExoPlayer player) {
      emitter.emit(state(id, player));
    }

    private Map<String, Object> state(int id, ExoPlayer player) {
      Map<String, Object> event = event(id, "state");
      event.put("playbackState", player.getPlaybackState());
      event.put("isPlaying", player.isPlaying());
      event.put("positionMs", player.getCurrentPosition());
      event.put("durationMs", Math.max(0, player.getDuration()));
      event.put("bufferedPositionMs", player.getBufferedPosition());
      event.put("videoWidth", player.getVideoSize().width);
      event.put("videoHeight", player.getVideoSize().height);
      return event;
    }

    synchronized Map<String, Object> state(int id) {
      PlayerSlot slot = slots.get(id);
      if (slot == null) throw new IllegalArgumentException("unknown playerId " + id);
      return state(id, slot.player);
    }

    private void scheduleProgress() {
      if (progressScheduled) return;
      progressScheduled = true;
      progressHandler.postDelayed(progressTicker, PROGRESS_INTERVAL_MS);
    }

    private static Map<String, Object> event(int id, String type) {
      Map<String, Object> event = new LinkedHashMap<>();
      event.put("playerId", id);
      event.put("type", type);
      return event;
    }

    private static String errorWithCauses(Throwable error) {
      StringBuilder message = new StringBuilder();
      Throwable current = error;
      while (current != null) {
        if (message.length() > 0) message.append("; caused by: ");
        message.append(current.getClass().getSimpleName());
        if (current.getMessage() != null && !current.getMessage().isEmpty()) {
          message.append(": ").append(current.getMessage());
        }
        if (current instanceof HttpDataSource.InvalidResponseCodeException) {
          byte[] body = ((HttpDataSource.InvalidResponseCodeException) current).responseBody;
          if (body.length > 0) {
            message.append("; response body: ")
                .append(new String(body, StandardCharsets.UTF_8));
          }
        }
        current = current.getCause();
      }
      return message.toString();
    }

    synchronized ExoPlayer player(int id) {
      PlayerSlot slot = slots.get(id);
      if (slot == null) throw new IllegalArgumentException("unknown playerId " + id);
      slot.lastUsed = System.nanoTime();
      return slot.player;
    }

    synchronized void releaseLease(int id) {
      PlayerSlot slot = slots.get(id);
      if (slot == null) return;
      slot.leases = Math.max(0, slot.leases - 1);
      slot.lastUsed = System.nanoTime();
      if (slot.leases != 0) return;
      slot.player.pause();
      if (slots.size() > maxPlayers) discardSlot(slot);
    }

    private void discardSlot(PlayerSlot slot) {
      slots.remove(slot.id);
      slot.player.release();
      slot.surface.release();
      slot.texture.release();
    }

    void preload(
        String cacheKey,
        String url,
        Map<String, String> headers,
        Runnable success,
        Consumer<Exception> failure) {
      ensureDiskCache();
      workers.execute(() -> {
        try {
          Bootstrap bootstrap = Bootstrap.load(http, url, headers);
          for (String resource : bootstrap.startupResources()) {
            String namespacedKey = cacheKey + ":" + sha256(resource);
            if (!memory.contains(namespacedKey)) {
              memory.put(namespacedKey, requestBytes(http, resource, headers));
            }
          }
          Map<String, Object> event = new LinkedHashMap<>();
          event.put("type", "preloaded");
          event.put("cacheKey", cacheKey);
          emitter.emit(event);
          success.run();
        } catch (Exception error) {
          Map<String, Object> event = new LinkedHashMap<>();
          event.put("type", "preloadError");
          event.put("cacheKey", cacheKey);
          event.put("message", error.getMessage());
          emitter.emit(event);
          failure.accept(error);
        }
      });
    }

    private DataSource.Factory dataSourceFactory(
        Map<String, String> headers, String cacheNamespace) {
      ensureDiskCache();
      OkHttpDataSource.Factory network = new OkHttpDataSource.Factory(http);
      network.setDefaultRequestProperties(headers);
      DefaultDataSource.Factory upstream = new DefaultDataSource.Factory(context, network);
      CacheDataSource.Factory cache = new CacheDataSource.Factory()
          .setCache(disk)
          .setUpstreamDataSourceFactory(upstream)
          .setCacheKeyFactory(spec -> cacheNamespace + ":" + sha256(spec.uri.toString()))
          .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR);
      return () -> new MemoryFirstDataSource(memory, cacheNamespace, cache.createDataSource());
    }

    synchronized void dispose() {
      progressHandler.removeCallbacks(progressTicker);
      progressScheduled = false;
      for (PlayerSlot slot : slots.values()) {
        slot.player.release();
        slot.surface.release();
        slot.texture.release();
      }
      slots.clear();
      workers.shutdownNow();
      if (disk != null) {
        try { disk.release(); } catch (Exception ignored) {}
        disk = null;
      }
    }

    private synchronized void ensureDiskCache() {
      if (disk == null) {
        disk = new SimpleCache(new File(context.getCacheDir(), "hls_cache_player"),
            new LeastRecentlyUsedCacheEvictor(configuredDiskBytes));
      }
    }
  }

  /** Reads preloaded startup bytes before falling back to Media3's disk/network source. */
  private static final class MemoryFirstDataSource implements DataSource {
    private final MemoryStore memory;
    private final String cacheNamespace;
    private final DataSource fallback;
    private ByteArrayInputStream input;
    private Uri uri;

    MemoryFirstDataSource(
        MemoryStore memory, String cacheNamespace, DataSource fallback) {
      this.memory = memory;
      this.cacheNamespace = cacheNamespace;
      this.fallback = fallback;
    }

    @Override public long open(DataSpec spec) throws IOException {
      uri = spec.uri;
      String cacheKey = cacheNamespace + ":" + sha256(uri.toString());
      byte[] bytes = memory.get(cacheKey);
      if (bytes == null) return fallback.open(spec);
      int start = (int) Math.min(bytes.length, spec.position);
      int available = bytes.length - start;
      int length = spec.length < 0 ? available : (int) Math.min(available, spec.length);
      input = new ByteArrayInputStream(bytes, start, length);
      return length;
    }

    @Override public int read(byte[] buffer, int offset, int length) throws IOException {
      return input == null ? fallback.read(buffer, offset, length) : input.read(buffer, offset, length);
    }
    @Override public Uri getUri() { return input == null ? fallback.getUri() : uri; }
    @Override public Map<String, List<String>> getResponseHeaders() {
      return input == null ? fallback.getResponseHeaders() : Collections.emptyMap();
    }
    @Override public void close() throws IOException {
      if (input == null) fallback.close(); else { input.close(); input = null; }
    }
    @Override public void addTransferListener(TransferListener listener) {
      fallback.addTransferListener(listener);
    }
  }

  /** Access-ordered, byte-bounded memory LRU. */
  private static final class MemoryStore {
    private final LinkedHashMap<String, byte[]> values = new LinkedHashMap<>(16, .75f, true);
    private long maxBytes;
    private long usedBytes;
    MemoryStore(long maxBytes) { this.maxBytes = maxBytes; }
    synchronized boolean contains(String key) { return values.containsKey(key); }
    synchronized byte[] get(String key) { return values.get(key); }
    synchronized void put(String key, byte[] value) {
      byte[] previous = values.put(key, value);
      if (previous != null) usedBytes -= previous.length;
      usedBytes += value.length;
      trim();
    }
    synchronized void setMaxBytes(long value) { maxBytes = value; trim(); }
    private void trim() {
      while (usedBytes > maxBytes && !values.isEmpty()) {
        Map.Entry<String, byte[]> eldest = values.entrySet().iterator().next();
        usedBytes -= eldest.getValue().length;
        values.remove(eldest.getKey());
      }
    }
  }

  /** Minimal VOD HLS parser: master variant, key, init map, and first media segment. */
  private static final class Bootstrap {
    final String entryUrl;
    final String playlistUrl;
    final String playlist;
    Bootstrap(String entryUrl, String playlistUrl, String playlist) {
      this.entryUrl = entryUrl;
      this.playlistUrl = playlistUrl;
      this.playlist = playlist;
    }

    static Bootstrap load(OkHttpClient client, String url, Map<String, String> headers)
        throws IOException {
      String text = requestText(client, url, headers);
      String[] lines = text.split("\\r?\\n");
      for (int index = 0; index < lines.length - 1; index++) {
        if (lines[index].startsWith("#EXT-X-STREAM-INF")) {
          String variant = resolve(url, lines[index + 1].trim());
          return new Bootstrap(url, variant, requestText(client, variant, headers));
        }
      }
      return new Bootstrap(url, url, text);
    }

    List<String> startupResources() {
      List<String> resources = new ArrayList<>();
      resources.add(entryUrl);
      if (!entryUrl.equals(playlistUrl)) {
      resources.add(playlistUrl);
      }
      boolean nextIsSegment = false;
      for (String raw : playlist.split("\\r?\\n")) {
        String line = raw.trim();
        if (line.startsWith("#EXT-X-MAP") || line.startsWith("#EXT-X-KEY")) {
          String value = uriAttribute(line);
          if (value != null) resources.add(resolve(playlistUrl, value));
        } else if (line.startsWith("#EXTINF")) {
          nextIsSegment = true;
        } else if (nextIsSegment && !line.isEmpty() && !line.startsWith("#")) {
          resources.add(resolve(playlistUrl, line));
          break;
        }
      }
      return resources;
    }

    private static String uriAttribute(String line) {
      int start = line.indexOf("URI=\"");
      if (start < 0) return null;
      start += 5;
      int end = line.indexOf('"', start);
      return end < 0 ? null : line.substring(start, end);
    }
  }

  private static String requestText(
      OkHttpClient client, String url, Map<String, String> headers) throws IOException {
    return new String(requestBytes(client, url, headers), StandardCharsets.UTF_8);
  }

  private static byte[] requestBytes(
      OkHttpClient client, String url, Map<String, String> headers) throws IOException {
    Request.Builder builder = new Request.Builder().url(url);
    headers.forEach(builder::header);
    try (Response response = client.newCall(builder.build()).execute()) {
      if (!response.isSuccessful() || response.body() == null) {
        throw new IOException("HTTP " + response.code() + " for " + url);
      }
      return response.body().bytes();
    }
  }

  private static String resolve(String base, String child) {
    return URI.create(base).resolve(child).toString();
  }

  private static String sha256(String value) {
    try {
      byte[] digest = MessageDigest.getInstance("SHA-256")
          .digest(value.getBytes(StandardCharsets.UTF_8));
      StringBuilder output = new StringBuilder();
      for (byte item : digest) output.append(String.format("%02x", item));
      return output.toString();
    } catch (Exception ignored) {
      return Integer.toHexString(value.hashCode());
    }
  }
}
