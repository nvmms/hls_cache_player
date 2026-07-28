package com.sinhonny.vertical_sliding_video;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.view.View;

import androidx.annotation.NonNull;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.TransferListener;
import androidx.media3.datasource.cache.CacheDataSource;
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor;
import androidx.media3.datasource.cache.SimpleCache;
import androidx.media3.datasource.okhttp.OkHttpDataSource;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.hls.HlsMediaSource;
import androidx.media3.ui.AspectRatioFrameLayout;
import androidx.media3.ui.PlayerView;

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
import io.flutter.plugin.common.StandardMessageCodec;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.plugin.platform.PlatformViewFactory;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

/** Native Media3 implementation and bounded player/cache pools. */
@UnstableApi
public final class VerticalSlidingVideoPlugin
    implements FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
  private MethodChannel methods;
  private EventChannel events;
  private EventChannel.EventSink eventSink;
  private VideoEngine engine;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    engine = new VideoEngine(binding.getApplicationContext(), this::emit);
    methods = new MethodChannel(binding.getBinaryMessenger(), "vertical_sliding_video/methods");
    methods.setMethodCallHandler(this);
    events = new EventChannel(binding.getBinaryMessenger(), "vertical_sliding_video/events");
    events.setStreamHandler(this);
    binding.getPlatformViewRegistry().registerViewFactory(
        "vertical_sliding_video/view", new VideoViewFactory(engine));
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
          result.success(engine.acquire(required(call, "cacheKey"), required(call, "url"),
              headers(call), Boolean.TRUE.equals(call.argument("autoPlay"))));
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
      result.error("vertical_sliding_video", error.getMessage(), null);
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

  private static final class VideoViewFactory extends PlatformViewFactory {
    private final VideoEngine engine;
    VideoViewFactory(VideoEngine engine) {
      super(StandardMessageCodec.INSTANCE);
      this.engine = engine;
    }
    @Override public PlatformView create(Context context, int viewId, Object args) {
      if (!(args instanceof Map) || !(((Map<?, ?>) args).get("playerId") instanceof Number)) {
        throw new IllegalArgumentException("playerId is required");
      }
      return new VideoPlatformView(
          context, engine, ((Number) ((Map<?, ?>) args).get("playerId")).intValue());
    }
  }

  private static final class VideoPlatformView implements PlatformView {
    private final PlayerView view;
    private final VideoEngine engine;
    private final int playerId;
    VideoPlatformView(Context context, VideoEngine engine, int playerId) {
      this.engine = engine;
      this.playerId = playerId;
      view = new PlayerView(context);
      view.setUseController(false);
      view.setResizeMode(AspectRatioFrameLayout.RESIZE_MODE_ZOOM);
      engine.attachView(playerId, view);
    }
    @Override public View getView() { return view; }
    @Override public void dispose() { engine.detachView(playerId, view); }
  }

  private static final class PlayerSlot {
    final int id;
    final ExoPlayer player;
    String cacheKey;
    int leases;
    long lastUsed;
    PlayerSlot(int id, ExoPlayer player) { this.id = id; this.player = player; }
  }

  private static final class VideoEngine {
    private final Context context;
    private final EventEmitter emitter;
    private final OkHttpClient http = new OkHttpClient();
    private final ExecutorService workers = Executors.newFixedThreadPool(2);
    private final Map<Integer, PlayerSlot> slots = new LinkedHashMap<>();
    private final Map<Integer, List<PlayerView>> attachedViews = new LinkedHashMap<>();
    private final MemoryStore memory = new MemoryStore(48L * 1024 * 1024);
    private SimpleCache disk;
    private int maxPlayers = 3;
    private int nextId = 1;

    VideoEngine(Context context, EventEmitter emitter) {
      this.context = context;
      this.emitter = emitter;
    }

    synchronized void configure(int players, long memoryBytes, long diskBytes) {
      if (disk != null) {
        throw new IllegalStateException("configure must be called before preload/acquire");
      }
      maxPlayers = Math.max(1, players);
      memory.setMaxBytes(Math.max(1024 * 1024, memoryBytes));
      disk = new SimpleCache(new File(context.getCacheDir(), "vertical_sliding_video"),
          new LeastRecentlyUsedCacheEvictor(Math.max(16L * 1024 * 1024, diskBytes)));
    }

    synchronized int acquire(
        String cacheKey, String url, Map<String, String> headers, boolean autoPlay) {
      PlayerSlot slot = null;
      for (PlayerSlot item : slots.values()) {
        if (cacheKey.equals(item.cacheKey)) { slot = item; break; }
      }
      boolean needsMedia = slot == null;
      if (slot == null) slot = obtainSlot();
      slot.cacheKey = cacheKey;
      slot.leases++;
      slot.lastUsed = System.nanoTime();
      if (needsMedia) {
        HlsMediaSource mediaSource = new HlsMediaSource.Factory(dataSourceFactory(headers, cacheKey))
            .createMediaSource(new MediaItem.Builder().setUri(url).setCustomCacheKey(cacheKey).build());
        slot.player.setMediaSource(mediaSource);
        slot.player.prepare();
      }
      if (autoPlay) slot.player.play();
      preload(cacheKey, url, headers, () -> {}, ignored -> {});
      return slot.id;
    }

    private PlayerSlot obtainSlot() {
      if (slots.size() < maxPlayers) return createSlot();
      PlayerSlot oldest = null;
      for (PlayerSlot slot : slots.values()) {
        if (slot.leases == 0 && (oldest == null || slot.lastUsed < oldest.lastUsed)) oldest = slot;
      }
      if (oldest == null) throw new IllegalStateException("all player pool entries are leased");
      oldest.player.stop();
      oldest.player.clearMediaItems();
      return oldest;
    }

    private PlayerSlot createSlot() {
      int id = nextId++;
      ExoPlayer player = new ExoPlayer.Builder(context).build();
      PlayerSlot slot = new PlayerSlot(id, player);
      player.addListener(new Player.Listener() {
        @Override public void onPlaybackStateChanged(int state) { emitState(id, player); }
        @Override public void onIsPlayingChanged(boolean playing) { emitState(id, player); }
        @Override public void onPlayerError(PlaybackException error) {
          Map<String, Object> event = event(id, "error");
          event.put("message", error.getMessage());
          emitter.emit(event);
        }
      });
      slots.put(id, slot);
      return slot;
    }

    private void emitState(int id, ExoPlayer player) {
      Map<String, Object> event = event(id, "state");
      event.put("playbackState", player.getPlaybackState());
      event.put("isPlaying", player.isPlaying());
      event.put("positionMs", player.getCurrentPosition());
      event.put("durationMs", Math.max(0, player.getDuration()));
      event.put("bufferedPositionMs", player.getBufferedPosition());
      emitter.emit(event);
    }

    private static Map<String, Object> event(int id, String type) {
      Map<String, Object> event = new LinkedHashMap<>();
      event.put("playerId", id);
      event.put("type", type);
      return event;
    }

    synchronized ExoPlayer player(int id) {
      PlayerSlot slot = slots.get(id);
      if (slot == null) throw new IllegalArgumentException("unknown playerId " + id);
      slot.lastUsed = System.nanoTime();
      return slot.player;
    }

    synchronized void attachView(int id, PlayerView view) {
      ExoPlayer player = player(id);
      List<PlayerView> views = attachedViews.computeIfAbsent(id, ignored -> new ArrayList<>());
      PlayerView previous = views.isEmpty() ? null : views.get(views.size() - 1);
      views.remove(view);
      views.add(view);
      PlayerView.switchTargetView(player, previous, view);
    }

    synchronized void detachView(int id, PlayerView view) {
      List<PlayerView> views = attachedViews.get(id);
      if (views == null) return;
      boolean wasCurrent = !views.isEmpty() && views.get(views.size() - 1) == view;
      views.remove(view);
      if (wasCurrent) {
        PlayerSlot slot = slots.get(id);
        PlayerView target = views.isEmpty() ? null : views.get(views.size() - 1);
        if (slot != null) PlayerView.switchTargetView(slot.player, view, target);
      } else {
        view.setPlayer(null);
      }
      if (views.isEmpty()) attachedViews.remove(id);
    }

    synchronized void releaseLease(int id) {
      PlayerSlot slot = slots.get(id);
      if (slot == null) return;
      slot.leases = Math.max(0, slot.leases - 1);
      slot.lastUsed = System.nanoTime();
      if (slot.leases == 0) slot.player.pause();
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
      for (PlayerSlot slot : slots.values()) slot.player.release();
      slots.clear();
      attachedViews.clear();
      workers.shutdownNow();
      if (disk != null) {
        try { disk.release(); } catch (Exception ignored) {}
        disk = null;
      }
    }

    private synchronized void ensureDiskCache() {
      if (disk == null) {
        disk = new SimpleCache(new File(context.getCacheDir(), "vertical_sliding_video"),
            new LeastRecentlyUsedCacheEvictor(768L * 1024 * 1024));
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
