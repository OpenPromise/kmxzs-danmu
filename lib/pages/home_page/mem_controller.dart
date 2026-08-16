part of '../home_page.dart';

/// 内存优化：定时对直播伴侣进程做 EmptyWorkingSet，降低后台占用。
mixin _MemController on _HomePageBase {
  List<String> get _memOptProcessNames {
    final name = _companionPath.replaceAll('\\', '/').split('/').last;
    if (name.isEmpty) {
      return const [
        'kwailive.exe',
        '直播伴侣.exe',
        'WebcastMate.exe',
        '直播伴侣 Launcher.exe',
        'TikTok LIVE Studio.exe',
        'TikTok LIVE Studio Launcher.exe',
      ];
    }
    return [name];
  }

  void _startMemOpt() {
    _memTimer?.cancel();
    _memTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _tickMemOpt(),
    );
  }

  void _stopMemOpt() {
    _memTimer?.cancel();
    _memTimer = null;
  }

  Future<void> _tickMemOpt() async {
    if (_memRunning) return;
    _memRunning = true;
    try {
      final trimmed =
          await MemOptimizer.instance.trimProcesses(_memOptProcessNames);
      if (trimmed > 0 &&
          (_lastMemLog == null ||
              DateTime.now().difference(_lastMemLog!) >=
                  const Duration(minutes: 1))) {
        _lastMemLog = DateTime.now();
        _appendLog('优化直播伴侣内存：已回收工作集');
      }
    } catch (e) {
      // 内存回收失败不打扰用户：静默一次，下个周期自动重试。
      debugPrint('[mem-opt] 回收工作集失败: $e');
    } finally {
      _memRunning = false;
    }
  }
}
