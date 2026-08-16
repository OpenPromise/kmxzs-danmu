part of '../home_page.dart';

/// 路径检测与设置：OBS / 直播伴侣路径探测、选择与首次使用引导。
///
/// 只涉及路径相关的本地逻辑，跨职责方法（拉流、授权等）由主 State 组装调用。
mixin _PathSetupController on _HomePageBase {
  Future<bool> _pathExists(String path) async {
    final p = path.trim();
    return p.isNotEmpty && await File(p).exists();
  }

  Future<void> _showPathSetupDialog() async {
    if (!mounted || _pathSetupShowing) return;
    _pathSetupShowing = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setLocal) {
              Future<void> refreshLocal() async {
                setLocal(() {});
                if (mounted) setState(() {});
              }

              return AlertDialog(
                title: const Text('首次使用设置'),
                content: SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '请设置 OBS 路径。直播伴侣可稍后在「一键开始」时选择，也可跳过由自己手动启动。',
                          style: TextStyle(fontSize: 13, height: 1.4),
                        ),
                        const SizedBox(height: 16),
                        _PathRow(
                          label: 'OBS Studio（obs64.exe）',
                          controller: _obsPathCtrl,
                          onDetect: () async {
                            await _detectObsPath(silent: false);
                            await refreshLocal();
                          },
                          onPick: () async {
                            await _pickObsPath();
                            await refreshLocal();
                          },
                          onChanged: (_) => setLocal(() {}),
                        ),
                        const SizedBox(height: 10),
                        _PathRow(
                          label: '直播伴侣（可选）',
                          controller: _companionPathCtrl,
                          onDetect: () async {
                            await _detectCompanionPath(silent: false);
                            await refreshLocal();
                          },
                          onPick: () async {
                            await _pickCompanionPath();
                            await refreshLocal();
                          },
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('稍后设置'),
                  ),
                  FilledButton(
                    onPressed: () async {
                      final obsOk = await _pathExists(_obsPathCtrl.text);
                      if (!obsOk) {
                        const msg = 'OBS 路径无效，请重新选择 obs64.exe';
                        if (!ctx.mounted) return;
                        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                          const SnackBar(
                            content: Text(msg),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                        if (ScaffoldMessenger.maybeOf(ctx) == null && mounted) {
                          _toast(msg);
                        }
                        return;
                      }
                      await _persist();
                      if (ctx.mounted) Navigator.pop(ctx);
                      _appendLog('已保存软件路径');
                      if (mounted) _toast('路径已保存');
                    },
                    child: const Text('完成'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      _pathSetupShowing = false;
    }
  }

  Future<void> _detectObsPath({bool silent = false}) async {
    final path = await _pathFinder.detectObsPath();
    if (path == null) {
      if (!silent) _toast('未检测到 OBS Studio，请手动选择 obs64.exe');
      return;
    }
    _obsPathCtrl.text = path;
    await _persist();
    if (!silent) _appendLog('OBS: $path');
    setState(() {});
  }

  Future<void> _detectCompanionPath({bool silent = false}) async {
    final path = await _pathFinder.detectCompanionPath();
    if (path == null) {
      if (!silent) _toast('未检测到直播伴侣，请手动选择可执行文件');
      return;
    }
    _companionPathCtrl.text = path;
    _skipCompanion = false;
    await _persist();
    if (!silent) _appendLog('直播伴侣: $path');
    setState(() {});
  }

  Future<void> _pickObsPath() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 obs64.exe',
      type: FileType.custom,
      allowedExtensions: ['exe'],
    );
    if (r == null || r.files.single.path == null) return;
    _obsPathCtrl.text = r.files.single.path!;
    await _persist();
    setState(() {});
  }

  Future<bool> _pickCompanionPath() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择直播伴侣',
      type: FileType.custom,
      allowedExtensions: ['exe'],
    );
    if (r == null || r.files.single.path == null) return false;
    _companionPathCtrl.text = r.files.single.path!;
    _skipCompanion = false;
    await _persist();
    setState(() {});
    return true;
  }

  /// 一键开始前：路径存在则启动；不存在则弹窗（可选路径 / 跳过）。
  /// 返回 false 表示用户取消，应中止流程。
  Future<bool> _prepareCompanionLaunch() async {
    final companion = _companionPath;
    if (companion.isNotEmpty && await File(companion).exists()) {
      await _launchExe(companion);
      return true;
    }
    if (_skipCompanion) {
      _appendLog('已跳过直播伴侣，请自行手动启动');
      return true;
    }
    if (!mounted) return false;
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('设置直播伴侣'),
          content: const Text(
            '尚未设置有效的直播伴侣路径。可以选择伴侣程序，'
            '或跳过（稍后自己手动打开直播伴侣）。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'skip'),
              child: const Text('跳过直播伴侣'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'pick'),
              child: const Text('选择路径'),
            ),
          ],
        );
      },
    );
    if (action == 'skip') {
      _skipCompanion = true;
      await _persist();
      _appendLog('已跳过直播伴侣路径设置，请自行手动启动');
      if (mounted) _toast('已跳过，请自行打开直播伴侣');
      return true;
    }
    if (action == 'pick') {
      final ok = await _pickCompanionPath();
      if (!ok) {
        _toast('未选择直播伴侣');
        return false;
      }
      await _launchExe(_companionPath);
      return true;
    }
    return false;
  }
}
