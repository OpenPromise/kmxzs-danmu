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

  String _friendlyPullError(String raw, {LivePlatform platform = LivePlatform.unknown}) {
    return PullErrorCopy.userFacing(raw, platform: platform);
  }

  void _startMediaMonitor() {
    _mediaTimer?.cancel();
    _mediaTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _tickMediaMonitor(),
    );
  }

  Future<void> _tickMediaMonitor() async {
    if (_busy || !mounted || _endStopRunning) return;
    final pull = await _obsWs.pullState();
    switch (_pullMonitor.update(pull)) {
      case PullMonitorAction.none:
        return;
      case PullMonitorAction.unstable:
        _appendLog('OBS 持续未拿到新画面，等待恢复中…');
        return;
      case PullMonitorAction.recovered:
        _appendLog('直播画面已恢复');
        try {
          _appendLog(await _obsWs.ensureVirtualCamStarted());
        } catch (e) {
          _appendLog('重启虚拟摄像机失败: $e');
        }
        if (mounted) setState(() => _status = '已就绪');
        return;
      case PullMonitorAction.ended:
        await _handleConfirmedMediaEnd();
        return;
    }
  }

  Future<void> _handleConfirmedMediaEnd() async {
    _endStopRunning = true;
    _appendLog('源直播持续未提供新画面，判定已结束');
    if (_autoStopOnMediaEnd) {
      final kind = _companionKind;
      if (!_skipCompanion && kind != CompanionKind.unknown) {
        _appendLog('正在发送关播快捷键（${kind.label}）…');
        final end = await CompanionStarter.instance.tryEndLive(
          kind: kind,
          hotkey: _effectiveEndHotkey,
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
