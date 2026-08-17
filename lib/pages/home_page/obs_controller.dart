part of '../home_page.dart';

/// OBS WebSocket 连接与媒体源/虚拟摄像机控制，以及拉流管线的 OBS 侧步骤。
mixin _ObsController on _HomePageBase {
  Future<void> _ensureObsReady() async {
    final fix = await _obsConfig.handleNew();
    _appendLog(
      fix.error == null ? '已自动配置 OBS' : 'OBS 自动配置未完成，请确认 OBS 已安装',
    );

    final running = await _obsConfig.isObsProcessRunning();
    final portOpen = await _obsConfig.isWebsocketPortOpen();
    final shouldRestart = running && (fix.needRestart || !portOpen);
    if (shouldRestart) {
      _appendLog('重启 OBS 以加载 WebSocket 配置...');
      await _obsConfig.killObsIfRunning();
    }

    if (!await _obsConfig.isObsProcessRunning()) {
      await _launchExe(
        _obsPathCtrl.text.trim(),
        args: const ['--disable-shutdown-check', '--disable-updater'],
      );
    }

    final ok = await _obsConfig.waitWebsocketPort(
      timeout: const Duration(seconds: 75),
      onProgress: _appendLog,
    );
    if (!ok) {
      throw StateError(
        '无法连接到 OBS WebSocket（网络或地址错误）\n'
        '请确认 OBS 已启动并启用了 WebSocket',
      );
    }
  }

  Future<void> _testObsWs({required bool silent}) async {
    await _persist();
    setState(() => _status = '连接中');
    try {
      await _ensureObsReady();
      await _obsWs.connectWithRetry(
        _wsUrlCtrl.text.trim(),
        maxAttempts: silent ? 10 : 5,
        gap: const Duration(seconds: 1),
        onAttempt: _appendLog,
      );
      setState(() => _status = '已连接');
      _appendLog('OBS WebSocket 已连接');
      if (!silent) _toast('测试连接成功');
    } catch (e) {
      setState(() => _status = '未连接');
      _appendLog('OBS 连接失败: $e');
      if (!silent) _toast('OBS 拒绝连接，请确认 OBS 已启动');
      rethrow;
    }
  }

  String _friendlyPullError(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('result=2') ||
        m.contains('400002') ||
        m.contains('操作频繁') ||
        m.contains('操作太快') ||
        m.contains('风控') ||
        m.contains('captcha')) {
      return '操作过于频繁，请关闭代理后等几分钟再试';
    }
    if (m.contains('tiktok')) {
      return 'TikTok 解析失败。请确认正在直播并关闭代理后重试';
    }
    if (m.contains('未开播') ||
        m.contains('not live') ||
        m.contains('offline') ||
        m.contains('直播已结束')) {
      return '直播间似乎未开播，请确认链接后重试';
    }
    if (m.contains('web_st') ||
        m.contains('cookie') ||
        m.contains('请先登录') ||
        m.contains('登录快手') ||
        m.contains('未登录')) {
      return '请先登录快手账号后再试';
    }
    if (m.contains('timeout') || m.contains('timed out') || m.contains('连接')) {
      return '网络连接失败。若开了代理，请先关闭或将目标域名设为直连';
    }
    if (raw.trim().isEmpty) return '拉流提取失败，请检查链接与网络';
    if (m.contains('滑块') ||
        m.contains('关闭快手') ||
        m.contains('未拿到') ||
        m.contains('webview') ||
        m.contains('间隔过短') ||
        m.contains('被风控') ||
        m.contains('秒后再试')) {
      return raw.trim();
    }
    return '拉流失败，请检查直播间链接与网络后重试';
  }

  void _startMediaMonitor() {
    _mediaTimer?.cancel();
    _mediaTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _tickMediaMonitor(),
    );
  }

  static const _endedTicksNeeded = 3;
  static const _playingTicksToCancel = 5;

  Future<void> _tickMediaMonitor() async {
    if (_busy || !mounted || _endStopRunning) return;
    final pull = await _obsWs.pullState();
    if (pull == PullState.idle) {
      _playingStreak = 0;
      return;
    }
    if (!_pullBaseline) {
      _pullBaseline = true;
      _wasPlaying = pull == PullState.playing;
      _endedStreak = 0;
      _playingStreak = 0;
      return;
    }
    if (pull == PullState.playing) {
      _playingStreak++;
      // ffmpeg 断流后会反复重连，单次 playing 不取消关播确认
      if (_playingStreak < _playingTicksToCancel) return;
      _endedStreak = 0;
      if (!_wasPlaying) {
        _wasPlaying = true;
        try {
          _appendLog(await _obsWs.ensureVirtualCamStarted());
        } catch (e) {
          _appendLog('重启虚拟摄像机失败: $e');
        }
        if (mounted) setState(() => _status = '已就绪');
      }
      return;
    }

    _playingStreak = 0;
    if (pull != PullState.ended || !_wasPlaying) return;

    _endedStreak++;
    if (_endedStreak == 1) {
      _appendLog('检测到源直播可能已结束，确认中…');
    }
    if (_endedStreak < _endedTicksNeeded) return;

    _wasPlaying = false;
    _endStopRunning = true;
    _appendLog('源直播已结束');
    if (_autoStopOnMediaEnd) {
      if (!_skipCompanion && _isKwaiCompanion) {
        _appendLog('正在发送关播快捷键…');
        final end = await KwaiLiveStarter.instance.tryEndLive(
          hotkey: _hotkeyCtrl.text,
        );
        _appendLog(end.message);
        if (!end.ok) {
          _toast('请在直播伴侣里点「结束直播」');
        }
      }
      await _obsWs.stopVirtualCam();
      _appendLog('已停止虚拟摄像机');
    }
    if (mounted) setState(() => _status = '已关播');
  }
}
