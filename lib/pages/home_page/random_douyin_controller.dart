part of '../home_page.dart';

mixin _RandomDouyinController
    on _HomePageBase, _LicenseController, _DanmakuController, _ObsController {
  static const _randomDouyinInterval = Duration(minutes: 30);

  void _startRandomDouyinTimer({bool runImmediately = false}) {
    if (!AppConfig.randomDouyinFeatureEnabled) return;
    _randomDouyinTimer?.cancel();
    _randomDouyinTimer = Timer.periodic(
      _randomDouyinInterval,
      (_) => unawaited(_runRandomDouyinCycle()),
    );
    if (runImmediately) {
      Future<void>.microtask(_runRandomDouyinCycle);
    }
  }

  Future<void> _setRandomDouyinEnabled(bool enabled) async {
    if (!AppConfig.randomDouyinFeatureEnabled) return;
    if (_randomDouyinEnabled == enabled) return;
    setState(() => _randomDouyinEnabled = enabled);
    await _persist();
    if (enabled) {
      _appendLog('已开启抖音随机轮播：立即获取一次，之后每30分钟切换');
      _startRandomDouyinTimer(runImmediately: true);
    } else {
      _randomDouyinTimer?.cancel();
      _randomDouyinTimer = null;
      _appendLog('已关闭抖音随机轮播（当前 OBS 画面保持不变）');
    }
  }

  Future<void> _runRandomDouyinCycle() async {
    if (!AppConfig.randomDouyinFeatureEnabled ||
        !_randomDouyinEnabled ||
        _randomDouyinRunning ||
        _busy ||
        !mounted) {
      return;
    }
    _randomDouyinRunning = true;
    setState(() => _busy = true);
    try {
      if (!await _ensureLicense()) return;
      final obs = _obsPathCtrl.text.trim();
      if (!await File(obs).exists()) {
        throw StateError('未找到 OBS，请先在设置中选择 obs64.exe');
      }

      _appendLog('===== 抖音随机轮播：正在发现直播间 =====');
      await _testObsWs(silent: true);
      final candidates = await _douyinRandomFinder.discoverCandidates(
        excludedWebRids: _recentRandomDouyinRids.toSet(),
      );

      FlvExtractResult? extracted;
      DouyinLiveCandidate? selected;
      final attempts = candidates.take(5);
      for (final candidate in attempts) {
        _appendLog(
          '尝试抖音房间 ${candidate.webRid}'
          '${candidate.anchor.isEmpty ? '' : ' · ${candidate.anchor}'}',
        );
        final result = await _flvExtractor.extract(candidate.roomUrl);
        if (result.ok && result.bestUrl().isNotEmpty) {
          extracted = result;
          selected = candidate;
          break;
        }
        _appendLog(
            '房间不可用，继续随机：${_friendlyPullError(result.message, platform: LivePlatform.douyin)}');
      }
      if (extracted == null || selected == null) {
        throw StateError('连续尝试5个推荐房间仍未解析到 OBS 可用地址');
      }

      _rememberRandomDouyinRid(selected.webRid);

      final candidatesForObs = extracted.playCandidates();
      _appendLog(
        await _obsWs.ensureRandomOverlayMediaSource(
          candidatesForObs.first,
          fallbacks: candidatesForObs.skip(1).toList(),
        ),
      );
      _appendLog(await _obsWs.ensureVirtualCamStarted());
      setState(() => _status = '已就绪');
      final detail = [selected.anchor, selected.title]
          .where((value) => value.trim().isNotEmpty)
          .join(' · ');
      _appendLog(
        '随机叠加层切换完成：${selected.roomUrl}${detail.isEmpty ? '' : ' · $detail'}',
      );
      _toast('已更新 OBS 顶层抖音画面（透明度 1% / 0.0100）');
    } catch (e) {
      _appendLog('抖音随机轮播失败: $e');
      _toast('随机抖音直播获取失败，30分钟后重试');
    } finally {
      _randomDouyinRunning = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  void _rememberRandomDouyinRid(String webRid) {
    _recentRandomDouyinRids.remove(webRid);
    _recentRandomDouyinRids.add(webRid);
    while (_recentRandomDouyinRids.length > 10) {
      _recentRandomDouyinRids.removeAt(0);
    }
  }
}
