import 'dart:async';

import 'package:obs_websocket/obs_websocket.dart';
import 'package:kmxzs/services/flv_extractor.dart';

enum ObsWsState { disconnected, connecting, connected, streaming }

/// 拉流媒体源状态（供主页轮询判断开播/关播）。
enum PullState { idle, playing, unstable, ended }

enum PullMonitorAction { none, unstable, recovered, ended }

class PullProbeResult {
  final PullState state;
  final int? lastCursor;
  final int stallTicks;

  const PullProbeResult({
    required this.state,
    required this.lastCursor,
    required this.stallTicks,
  });
}

class PullMonitorPolicy {
  static const int playingTicksToRecover = 3;
  static const int unstableTicksToEnd = 7;
  static const int endedTicksToEnd = 6;

  bool _baseline = false;
  bool _wasPlaying = false;
  bool _unstableLogged = false;
  int _playingStreak = 0;
  int _unstableStreak = 0;
  int _endedStreak = 0;

  void reset() {
    _baseline = false;
    _wasPlaying = false;
    _unstableLogged = false;
    _playingStreak = 0;
    _unstableStreak = 0;
    _endedStreak = 0;
  }

  PullMonitorAction update(PullState pull) {
    if (pull == PullState.idle) {
      _playingStreak = 0;
      return PullMonitorAction.none;
    }
    if (!_baseline) {
      _baseline = true;
      _wasPlaying = pull == PullState.playing;
      _playingStreak = 0;
      _unstableStreak = 0;
      _endedStreak = 0;
      _unstableLogged = false;
      return PullMonitorAction.none;
    }
    if (pull == PullState.playing) {
      _playingStreak++;
      if (_playingStreak < playingTicksToRecover) {
        return PullMonitorAction.none;
      }
      final recovered = !_wasPlaying ||
          _unstableLogged ||
          _unstableStreak > 0 ||
          _endedStreak > 0;
      _wasPlaying = true;
      _unstableLogged = false;
      _unstableStreak = 0;
      _endedStreak = 0;
      return recovered ? PullMonitorAction.recovered : PullMonitorAction.none;
    }

    _playingStreak = 0;
    if (!_wasPlaying) return PullMonitorAction.none;

    if (pull == PullState.unstable) {
      _unstableStreak++;
      _endedStreak = 0;
      if (!_unstableLogged) {
        _unstableLogged = true;
        return PullMonitorAction.unstable;
      }
      if (_unstableStreak < unstableTicksToEnd) {
        return PullMonitorAction.none;
      }
      _wasPlaying = false;
      _unstableLogged = false;
      _unstableStreak = 0;
      _endedStreak = 0;
      return PullMonitorAction.ended;
    }

    _endedStreak++;
    _unstableStreak = 0;
    if (_endedStreak < endedTicksToEnd) {
      return PullMonitorAction.none;
    }
    _wasPlaying = false;
    _unstableLogged = false;
    _endedStreak = 0;
    return PullMonitorAction.ended;
  }
}

class ObsWs {
  ObsWebSocket? _client;
  ObsWsState state = ObsWsState.disconnected;
  int? _lastMediaCursor;
  int _cursorStallTicks = 0;

  static const mediaSourceName = '直播拉流';

  static PullProbeResult probeMediaStatus({
    required ObsMediaState mediaState,
    required int? lastCursor,
    required int? mediaCursor,
    required int stallTicks,
    int unstableAfterStallTicks = 1,
  }) {
    switch (mediaState) {
      case ObsMediaState.playing:
      case ObsMediaState.opening:
      case ObsMediaState.buffering:
        final cursor = mediaCursor ?? 0;
        if (lastCursor != null && cursor == lastCursor) {
          final nextStallTicks = stallTicks + 1;
          if (nextStallTicks >= unstableAfterStallTicks) {
            return PullProbeResult(
              state: PullState.unstable,
              lastCursor: lastCursor,
              stallTicks: nextStallTicks,
            );
          }
          return PullProbeResult(
            state: PullState.playing,
            lastCursor: lastCursor,
            stallTicks: nextStallTicks,
          );
        }
        return PullProbeResult(
          state: PullState.playing,
          lastCursor: cursor,
          stallTicks: 0,
        );
      case ObsMediaState.stopped:
      case ObsMediaState.ended:
      case ObsMediaState.error:
        return const PullProbeResult(
          state: PullState.ended,
          lastCursor: null,
          stallTicks: 0,
        );
      case ObsMediaState.paused:
      case ObsMediaState.none:
        return const PullProbeResult(
          state: PullState.idle,
          lastCursor: null,
          stallTicks: 0,
        );
    }
  }

  Future<void> connect(String url, {String? password}) async {
    state = ObsWsState.connecting;
    try {
      await disconnect();
      // 外层再套硬超时：部分环境下包内 timeout 不会生效，会一直挂起
      _client = await ObsWebSocket.connect(
        url,
        password: password,
        timeout: const Duration(seconds: 5),
      ).timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw TimeoutException('OBS WebSocket 连接超时'),
      );
      state = ObsWsState.connected;
    } catch (e) {
      state = ObsWsState.disconnected;
      _client = null;
      rethrow;
    }
  }

  /// 轮询重试，适合 OBS 刚启动、WebSocket 尚未监听的场景。
  Future<void> connectWithRetry(
    String url, {
    String? password,
    int maxAttempts = 15,
    Duration gap = const Duration(seconds: 2),
    void Function(String msg)? onAttempt,
  }) async {
    Object? lastError;
    for (var i = 1; i <= maxAttempts; i++) {
      onAttempt?.call('第 $i/$maxAttempts 次连接 $url ...');
      try {
        await connect(url, password: password);
        onAttempt?.call('连接成功');
        return;
      } catch (e) {
        lastError = e;
        state = ObsWsState.disconnected;
        onAttempt?.call('失败: $e');
        if (i < maxAttempts) await Future.delayed(gap);
      }
    }
    throw lastError ?? StateError('OBS WebSocket 连接失败');
  }

  Future<void> disconnect() async {
    try {
      await _client?.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 关闭已断开的连接抛错可安全忽略，后续统一置空
    }
    _client = null;
    if (state != ObsWsState.disconnected) {
      state = ObsWsState.disconnected;
    }
  }

  ObsWebSocket get _requireClient {
    final c = _client;
    if (c == null) throw StateError('未连接到 OBS WebSocket');
    return c;
  }

  static bool _isHls(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') ||
        lower.contains('/hls_') ||
        lower.contains('manifest/hls') ||
        lower.contains('googlevideo.com/api/manifest');
  }

  static bool _isFlv(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.flv') ||
        lower.contains('pull-flv') ||
        lower.contains('/flv/');
  }

  static bool _needsBrowserHeaders(String url) {
    final lower = url.toLowerCase();
    return lower.contains('bilivideo') ||
        lower.contains('bilibili') ||
        lower.contains('xhscdn') ||
        lower.contains('xiaohongshu') ||
        lower.contains('googlevideo') ||
        lower.contains('youtube') ||
        lower.contains('ytimg') ||
        _isHls(url);
  }

  static String _ffmpegOpts(String url) {
    final parts = <String>[
      'reconnect=1',
      'reconnect_streamed=1',
      'reconnect_delay_max=5',
      'rw_timeout=15000000',
    ];
    if (_needsBrowserHeaders(url)) {
      parts.insert(0, 'user_agent=${FlvExtractor.browserUa}');
    }
    final lower = url.toLowerCase();
    if (lower.contains('bilivideo') || lower.contains('bilibili')) {
      // B站 CDN 无 Referer 会立刻 403，OBS 表现为 mediaState=ended、无画面
      parts.add('referer=https://live.bilibili.com/');
    }
    if (lower.contains('xhscdn') || lower.contains('xiaohongshu')) {
      parts.add('referer=https://www.xiaohongshu.com/');
    }
    return parts.join(' ');
  }

  /// 在当前场景创建/更新「媒体源」，用网络 FLV/HLS 作为画面输入。
  /// [fallbacks] 在首条立刻 ended 时依次尝试（B站运营商线路常失败）。
  Future<String> ensurePullMediaSource(
    String mediaUrl, {
    List<String> fallbacks = const [],
  }) async {
    final seen = <String>{};
    final urls = <String>[];
    for (final u in [mediaUrl, ...fallbacks]) {
      final t = u.trim();
      if (t.isEmpty || !seen.add(t)) continue;
      urls.add(t);
    }
    if (urls.isEmpty) return '无拉流地址';

    String last = '';
    for (var i = 0; i < urls.length; i++) {
      last = await _applyPullMediaUrl(urls[i]);
      final playing = last.contains('playing') ||
          last.contains('opening') ||
          last.contains('buffering');
      if (playing) return last;
      final dead = last.contains('ended') ||
          last.contains('error') ||
          last.contains('stopped');
      if (dead && i < urls.length - 1) {
        last = '$last\n线路无画面，换备用地址 (${i + 2}/${urls.length})';
        continue;
      }
      if (!dead) return last;
    }
    return last;
  }

  Future<String> _applyPullMediaUrl(String mediaUrl) async {
    final c = _requireClient;
    final scene = await c.scenes.getCurrentProgramScene().timeout(
          const Duration(seconds: 8),
        );

    final isHls = _isHls(mediaUrl);
    final isFlv = _isFlv(mediaUrl);
    final format = isHls ? 'hls' : (isFlv ? 'flv' : '');
    final ffmpegOpts = _ffmpegOpts(mediaUrl);

    final settings = <String, dynamic>{
      'is_local_file': false,
      'local_file': '',
      'input': mediaUrl,
      'input_format': format,
      'reconnect_delay_sec': 3,
      'hw_decode': false, // 网络流硬解易黑屏
      'clear_on_media_end': false,
      'restart_on_activate': true,
      'close_when_inactive': false,
      'speed_percent': 100,
      'color_range': 0,
      'looping': false,
      'seekable': false,
      'ffmpeg_options': ffmpegOpts,
    };

    final inputs = await c.inputs.getInputList(null).timeout(
          const Duration(seconds: 8),
        );
    final exists = inputs.any((i) => i.inputName == mediaSourceName);
    if (exists) {
      await c.inputs
          .setInputSettings(
            inputName: mediaSourceName,
            inputSettings: settings,
            overlay: false, // 完整覆盖设置，避免旧参数残留
          )
          .timeout(const Duration(seconds: 8));
    } else {
      await c.inputs
          .createInput(
            sceneName: scene,
            inputName: mediaSourceName,
            inputKind: 'ffmpeg_source',
            inputSettings: settings,
            sceneItemEnabled: true,
          )
          .timeout(const Duration(seconds: 8));
    }

    await Future.delayed(const Duration(milliseconds: 800));
    try {
      await c.mediaInputs
          .triggerMediaInputAction(
            inputName: mediaSourceName,
            mediaAction: ObsMediaInputAction.restart,
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // restart 不可用时回退到 play；仍失败则交给上层日志
      try {
        await c.mediaInputs.triggerMediaInputAction(
          inputName: mediaSourceName,
          mediaAction: ObsMediaInputAction.play,
        );
      } catch (_) {
        // play 也失败表示 OBS 状态异常，让上层报错即可，这里不再补日志
      }
    }

    await Future.delayed(Duration(milliseconds: isHls ? 1800 : 1200));
    try {
      await c.mediaInputs.getMediaInputStatus(
        inputName: mediaSourceName,
      );
    } catch (_) {
      // 查询失败不影响已经写入的媒体源，只影响日志
    }
    return '已把直播画面加入 OBS';
  }

  /// 新一次拉流开始时清掉进度卡住计数。
  void resetPullMonitor() {
    _lastMediaCursor = null;
    _cursorStallTicks = 0;
  }

  /// 读取「直播拉流」媒体源的开播/关播状态；未连接或无媒体源时返回 idle。
  Future<PullState> pullState() async {
    final c = _client;
    if (c == null) return PullState.idle;
    try {
      final st = await c.mediaInputs
          .getMediaInputStatus(inputName: mediaSourceName)
          .timeout(const Duration(seconds: 5));
      final probed = probeMediaStatus(
        mediaState: st.mediaState,
        lastCursor: _lastMediaCursor,
        mediaCursor: st.mediaCursor,
        stallTicks: _cursorStallTicks,
      );
      _lastMediaCursor = probed.lastCursor;
      _cursorStallTicks = probed.stallTicks;
      return probed.state;
    } catch (_) {
      // 拉不到状态按 idle 处理（不触发关播/开播逻辑），避免误判
      return PullState.idle;
    }
  }

  Future<void> setStreamAndStart({
    required String server,
    required String key,
  }) async {
    final c = _requireClient;

    try {
      final status = await c.stream.status.timeout(const Duration(seconds: 5));
      if (status.outputActive == true) {
        await c.stream.stopStream().timeout(const Duration(seconds: 5));
        await Future.delayed(const Duration(milliseconds: 800));
      }
    } catch (_) {
      // 切换推流服务前停止旧推流属尽力而为，失败继续覆盖配置
    }

    await c.config.setStreamServiceSettings(
      streamServiceType: 'rtmp_custom',
      streamServiceSettings: {
        'server': server,
        'key': key,
      },
    ).timeout(const Duration(seconds: 8));
    await c.stream.startStream().timeout(const Duration(seconds: 8));
    state = ObsWsState.streaming;
  }

  Future<void> stopStreaming() async {
    final c = _client;
    if (c == null) return;
    try {
      await c.stream.stopStream().timeout(const Duration(seconds: 5));
    } catch (_) {
      // 停止推流失败不影响连接状态标记，可安全忽略
    }
    state = ObsWsState.connected;
  }

  /// 确保 OBS 虚拟摄像机已开启（供快手伴侣采集「OBS Virtual Camera」）。
  Future<String> ensureVirtualCamStarted() async {
    final c = _requireClient;
    try {
      final active = await c.outputs.getVirtualCamStatus().timeout(
            const Duration(seconds: 5),
          );
      if (active) {
        return '虚拟摄像机已在运行';
      }
    } catch (_) {
      // 查询虚拟摄像机状态失败不阻塞，继续尝试 StartVirtualCam
    }

    try {
      await c.outputs.startVirtualCam().timeout(const Duration(seconds: 8));
    } catch (e) {
      // 部分版本 Start 在已开启时会报错，再 Toggle 一次兜底
      try {
        final on = await c.outputs.toggleVirtualCam().timeout(
              const Duration(seconds: 8),
            );
        if (on) return '虚拟摄像机已开启（toggle）';
        // toggle 关掉了，再开一次
        await c.outputs.startVirtualCam().timeout(const Duration(seconds: 8));
      } catch (e2) {
        throw StateError(
          '启动虚拟摄像机失败: $e / $e2\n'
          '请确认 OBS 已安装虚拟摄像机（工具栏「启动虚拟摄像机」可用）',
        );
      }
    }

    await Future.delayed(const Duration(milliseconds: 400));
    try {
      final ok = await c.outputs.getVirtualCamStatus().timeout(
            const Duration(seconds: 5),
          );
      if (!ok) {
        throw StateError('已发送启动指令，但虚拟摄像机仍未激活');
      }
      return '虚拟摄像机已启动';
    } catch (e) {
      if (e is StateError) rethrow;
      return '已发送 StartVirtualCam（状态回读失败: $e）';
    }
  }

  Future<void> stopVirtualCam() async {
    final c = _client;
    if (c == null) return;
    try {
      await c.outputs.stopVirtualCam().timeout(const Duration(seconds: 5));
    } catch (_) {
      // 停止虚拟摄像机失败（如已停止）可安全忽略
    }
  }
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  @override
  String toString() => message;
}
